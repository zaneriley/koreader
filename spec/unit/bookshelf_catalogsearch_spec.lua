describe("Bookshelf catalog search", function()
    local CatalogSearch

    -- Trimmed from a live calibre-web OPDS root feed: both search link styles,
    -- the OpenSearch description preferred by discovery.
    local ROOT_FEED = [[<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>urn:uuid:root</id>
  <link rel="search" href="/opds/osd" type="application/opensearchdescription+xml"/>
  <link rel="search" type="application/atom+xml" title="Search" href="/opds/search/{searchTerms}"/>
  <entry>
    <title>Alphabetical Books</title>
    <id>urn:uuid:nav1</id>
    <link rel="subsection" href="/opds/books" type="application/atom+xml;profile=opds-catalog"/>
  </entry>
</feed>]]

    -- Real calibre-web shape: a text/html Url candidate before the atom one;
    -- discovery must pick the atom template.
    local OSD_DOC = [[<?xml version="1.0" encoding="UTF-8"?>
<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
  <Url type="text/html" template="/opds/search/{searchTerms}"/>
  <Url type="application/atom+xml" template="/opds/search/{searchTerms}"/>
</OpenSearchDescription>]]

    -- Trimmed from the live search feed: multi-author entry with a relative
    -- EPUB acquisition href, plus a PDF-only entry that must be excluded.
    local SEARCH_FEED = [[<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:dcterms="http://purl.org/dc/terms/">
  <id>urn:uuid:search</id>
  <entry>
    <title>Difficult Conversations: How to Discuss What Matters Most</title>
    <id>urn:uuid:book1</id>
    <author><name>Douglas Stone</name></author>
    <author><name>Sheila Heen</name></author>
    <link rel="http://opds-spec.org/acquisition" href="/opds/download/306/epub/"
          length="1252498" title="EPUB" type="application/epub+zip"/>
  </entry>
  <entry>
    <title>No EPUB Here</title>
    <id>urn:uuid:book2</id>
    <author><name>Nobody</name></author>
    <link rel="http://opds-spec.org/acquisition" href="/opds/download/307/pdf/"
          type="application/pdf"/>
  </entry>
</feed>]]

    local SERVER = {
        title = "My Library",
        url = "http://lib.example/opds",
        username = "rye",
        password = "secret",
    }

    local function fakeHttp(routes, log)
        return {
            request = function(req)
                if log then
                    table.insert(log, { url = req.url, user = req.user, password = req.password })
                end
                local body = routes[req.url]
                if not body then
                    return 1, 404, {}, "HTTP/1.1 404 Not Found"
                end
                req.sink(body)
                req.sink(nil)
                return 1, 200, {}, "HTTP/1.1 200 OK"
            end,
        }
    end

    setup(function()
        require("commonrequire")
        -- the real opds modules load offline once their plugin dir is on the path
        package.path = "plugins/opds.koplugin/?.lua;" .. package.path
        CatalogSearch = dofile("plugins/bookshelf.koplugin/catalogsearch.lua")
    end)

    it("is unavailable when the opds plugin modules cannot load", function()
        local cs = CatalogSearch.new{ parser = false, opds_browser = false }
        assert.is_false(cs:available())
    end)

    it("returns only a credentialed server, never the public defaults", function()
        local cs = CatalogSearch.new{
            settings_open = function()
                return {
                    readSetting = function(_, key)
                        assert.equals("servers", key)
                        return {
                            { title = "Project Gutenberg", url = "https://m.gutenberg.org/ebooks.opds/?format=opds" },
                            { title = "My Library", url = SERVER.url, username = "rye", password = "secret" },
                        }
                    end,
                }
            end,
        }
        local server = cs:getServer()
        assert.equals("My Library", server.title)
        assert.equals("rye", server.username)
    end)

    it("returns nil when no credentialed server is configured", function()
        local cs = CatalogSearch.new{
            settings_open = function()
                return {
                    readSetting = function()
                        return {
                            { title = "Project Gutenberg", url = "https://m.gutenberg.org/ebooks.opds/?format=opds" },
                        }
                    end,
                }
            end,
        }
        assert.is_nil(cs:getServer())
    end)

    it("discovers the search template, searches, and extracts epub results", function()
        local log = {}
        local cs = CatalogSearch.new{
            http = fakeHttp({
                ["http://lib.example/opds"] = ROOT_FEED,
                ["http://lib.example/opds/osd"] = OSD_DOC,
                ["http://lib.example/opds/search/conversations"] = SEARCH_FEED,
            }, log),
        }
        local results, err = cs:search(SERVER, "conversations")

        assert.is_nil(err)
        assert.equals(1, #results) -- the PDF-only entry is excluded
        local hit = results[1]
        assert.is_truthy(hit.title:find("Difficult Conversations", 1, true))
        assert.is_truthy(hit.author:find("Sheila Heen", 1, true))
        -- relative acquisition href came back absolutized
        assert.equals("http://lib.example/opds/download/306/epub/", hit.epub_href)
        -- basic auth flowed into every request
        for _, req in ipairs(log) do
            assert.equals("rye", req.user)
            assert.equals("secret", req.password)
        end
    end)

    it("memoizes the search template per instance", function()
        local log = {}
        local cs = CatalogSearch.new{
            http = fakeHttp({
                ["http://lib.example/opds"] = ROOT_FEED,
                ["http://lib.example/opds/osd"] = OSD_DOC,
                ["http://lib.example/opds/search/one"] = SEARCH_FEED,
                ["http://lib.example/opds/search/two"] = SEARCH_FEED,
            }, log),
        }
        cs:search(SERVER, "one")
        local first_count = #log
        cs:search(SERVER, "two")
        -- the second search adds exactly one request: the search feed itself
        assert.equals(first_count + 1, #log)
    end)

    it("reports fetch failures as short error codes", function()
        local cs = CatalogSearch.new{
            http = fakeHttp({}), -- every url 404s
        }
        local results, err = cs:search(SERVER, "anything")
        assert.is_nil(results)
        assert.equals("404", err)
    end)

    it("downloads an epub into the download dir with collision suffixing", function()
        local lfs = require("libs/libkoreader-lfs")
        local dir = "/tmp/bookshelf-catalogsearch-spec"
        os.execute("rm -rf " .. dir)
        lfs.mkdir(dir)

        local cs = CatalogSearch.new{
            http = fakeHttp({
                ["http://lib.example/opds/download/306/epub/"] = "EPUBDATA",
            }),
        }
        local result = {
            title = "Difficult Conversations",
            author = "Sheila Heen",
            epub_href = "http://lib.example/opds/download/306/epub/",
        }

        local path, err = cs:download(SERVER, result, { download_dir = dir })
        assert.is_nil(err)
        local f = io.open(path, "r")
        assert.equals("EPUBDATA", f:read("*a"))
        f:close()

        -- a second download of the same book gets a numeric suffix
        local path2 = cs:download(SERVER, result, { download_dir = dir })
        assert.is_truthy(path2:find("%(1%)%.epub$"))

        os.execute("rm -rf " .. dir)
    end)

    it("refuses non-http acquisition urls", function()
        local cs = CatalogSearch.new{ http = fakeHttp({}) }
        local path, err = cs:download(SERVER, { epub_href = "ftp://lib.example/x.epub" }, { download_dir = "/tmp" })
        assert.is_nil(path)
        assert.is_truthy(err:find("invalid protocol", 1, true))
    end)
end)
