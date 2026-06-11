-- Catalog search/download for the bookshelf's layered library search.
-- Wraps the stock OPDS plugin's parser and feed-to-items transformation so the
-- bookshelf never hand-rolls XML or HTTP semantics. Pure return values: no
-- UIManager dialogs here, the UI layer decides what to show. Every dependency
-- is injectable for specs; defaults resolve lazily at call time, when
-- PluginLoader has already appended enabled plugin dirs to package.path
-- (the same mechanism opdsbrowser uses for its own requires).

local CatalogSearch = {
    -- mirrors opdsbrowser.lua's search link constants
    SEARCH_TYPE = "application/opensearchdescription%+xml",
    SEARCH_TEMPLATE_TYPE = "application/atom%+xml",
}

function CatalogSearch.new(deps)
    -- The search template is effectively static per server (calibre-web:
    -- /opds/search/{searchTerms}); memoize it per instance so repeated
    -- searches within one shelf-open skip the discovery round-trips.
    return setmetatable({
        _deps = deps or {},
        _template_cache = {},
    }, { __index = CatalogSearch })
end

function CatalogSearch:_dep(name)
    local value = self._deps[name]
    if value ~= nil then
        return value
    end
    if name == "http" then
        value = require("socket.http")
    elseif name == "socket" then
        value = require("socket")
    elseif name == "url" then
        value = require("socket.url")
    elseif name == "socketutil" then
        value = require("socketutil")
    elseif name == "util" then
        value = require("util")
    elseif name == "lfs" then
        value = require("libs/libkoreader-lfs")
    elseif name == "parser" then
        local ok, mod = pcall(require, "opdsparser")
        value = ok and mod or false
    elseif name == "opds_browser" then
        local ok, mod = pcall(require, "opdsbrowser")
        value = ok and mod or false
    elseif name == "settings_open" then
        value = function()
            local DataStorage = require("datastorage")
            local LuaSettings = require("luasettings")
            return LuaSettings:open(DataStorage:getSettingsDir() .. "/opds.lua")
        end
    elseif name == "reader_settings" then
        value = G_reader_settings
    end
    self._deps[name] = value
    return value
end

-- The whole remote layer gates on the stock OPDS plugin being enabled; when
-- it is disabled these requires fail and the "In your library" section
-- simply does not render.
function CatalogSearch:available()
    return self:_dep("parser") ~= false and self:_dep("opds_browser") ~= false
end

-- The user's own catalog is a configured server WITH credentials. No default
-- is passed when reading the servers setting: the stock OPDS plugin persists
-- its public default servers (Project Gutenberg et al) into the same file,
-- and a public catalog must never be searched under an "In your library"
-- heading.
function CatalogSearch:getServer()
    local ok, settings = pcall(self:_dep("settings_open"))
    if not ok or not settings then
        return nil
    end
    local servers = settings:readSetting("servers")
    if type(servers) ~= "table" then
        return nil
    end
    for _, server in ipairs(servers) do
        if type(server.username) == "string" and server.username ~= "" and server.url then
            return {
                title = server.title,
                url = server.url,
                username = server.username,
                password = server.password,
            }
        end
    end
    return nil
end

function CatalogSearch:_fetch(target_url, username, password)
    local socketutil = self:_dep("socketutil")
    local http = self:_dep("http")
    local socket = self:_dep("socket")
    local sink_table = {}
    -- Tighter than stock OPDS (10s/30s): search is a passive fill-in, a dead
    -- server must not hang the UI. table_sink enforces the total cap.
    socketutil:set_timeout(3, 5)
    local code = socket.skip(1, http.request{
        url = target_url,
        method = "GET",
        headers = { ["Accept-Encoding"] = "identity" },
        sink = socketutil.table_sink(sink_table),
        user = username,
        password = password,
    })
    socketutil:reset_timeout()
    if code == 200 then
        local body = table.concat(sink_table)
        if body ~= "" then
            return body
        end
        return nil, "empty response"
    end
    return nil, code and tostring(code) or "network unreachable"
end

function CatalogSearch:_fetchParsed(target_url, server)
    local body, err = self:_fetch(target_url, server.username, server.password)
    if not body then
        return nil, err
    end
    local parser = self:_dep("parser")
    local ok, catalog = pcall(parser.parse, parser, body)
    if not ok or type(catalog) ~= "table" then
        return nil, "unparseable feed"
    end
    return catalog
end

-- Same two-branch link scan as opdsbrowser's genItemTableFromCatalog: an
-- OpenSearch description document, else a calibre-style direct search link
-- carrying {searchTerms} in its href.
function CatalogSearch:_discoverTemplate(server)
    local url = self:_dep("url")
    local catalog, err = self:_fetchParsed(server.url, server)
    if not catalog then
        return nil, err
    end
    local feed = catalog.feed or catalog
    local function absolute(href)
        return url.absolute(server.url, href)
    end
    local calibre_template
    for _, link in ipairs(feed.link or {}) do
        if link.type and link.href then
            if link.type:find(self.SEARCH_TYPE) then
                local osd = self:_fetchParsed(absolute(link.href), server)
                local urls = osd and osd.OpenSearchDescription and osd.OpenSearchDescription.Url
                if urls then
                    for _, candidate in ipairs(urls) do
                        if candidate.type and candidate.template
                            and candidate.type:find(self.SEARCH_TEMPLATE_TYPE) then
                            return absolute((candidate.template:gsub("{searchTerms}", "%%s")))
                        end
                    end
                end
            elseif link.type:find(self.SEARCH_TEMPLATE_TYPE)
                and link.rel and link.rel:find("search") then
                calibre_template = absolute((link.href:gsub("{searchTerms}", "%%s")))
            end
        end
    end
    if calibre_template then
        return calibre_template
    end
    return nil, "catalog has no search support"
end

function CatalogSearch:_resultsFromCatalog(catalog, result_url)
    local Browser = self:_dep("opds_browser")
    -- Throwaway pseudo-instance: genItemTableFromCatalog touches no Menu
    -- widget state, and sync = true makes it a pure feed->items transform
    -- (skips nested OpenSearch discovery and facet collection). Never call it
    -- on the class table itself: it mutates fields, and require caches the
    -- module shared with the real OPDS browser.
    local browser = Browser:extend{ sync = true }
    local items = browser:genItemTableFromCatalog(catalog, result_url)
    local results = {}
    for _, item in ipairs(items or {}) do
        local epub
        for _, acq in ipairs(item.acquisitions or {}) do
            -- mimetype is canonical (calibre-web sets it); the filetype helper
            -- is best-effort for suffix-style hrefs
            if acq.href and (acq.type == "application/epub+zip"
                or Browser.getFiletype(acq) == "epub") then
                epub = acq
                break
            end
        end
        if epub then
            table.insert(results, {
                title = item.title,
                author = item.author,
                text = item.text,
                epub_href = epub.href, -- absolutized by genItemTableFromCatalog
                mimetype = epub.type,
            })
        end
    end
    return results
end

function CatalogSearch:search(server, query)
    local template = self._template_cache[server.url]
    if not template then
        local err
        template, err = self:_discoverTemplate(server)
        if not template then
            return nil, err
        end
        self._template_cache[server.url] = template
    end
    local encoded = self:_dep("util").urlEncode(query)
    -- function replacement so % in the query is never a capture reference
    local search_url = template:gsub("%%s", function() return encoded end)
    local catalog, err = self:_fetchParsed(search_url, server)
    if not catalog then
        -- template may be stale; rediscover once on the next call
        self._template_cache[server.url] = nil
        return nil, err
    end
    return self:_resultsFromCatalog(catalog, search_url)
end

-- Downloads one search result's EPUB into the shelf's download dir.
-- Returns local_path on success; nil, err on failure. Synchronous: the
-- caller paints its "Downloading..." beat first and schedules this after.
function CatalogSearch:download(server, result, opts)
    opts = opts or {}
    local lfs = self:_dep("lfs")
    local util = self:_dep("util")
    local url = self:_dep("url")
    local socketutil = self:_dep("socketutil")
    local http = self:_dep("http")
    local socket = self:_dep("socket")
    local reader_settings = self:_dep("reader_settings")

    local download_dir = opts.download_dir
        or reader_settings:readSetting("download_dir")
        or reader_settings:readSetting("lastdir")
    if not download_dir then
        return nil, "no download folder configured"
    end

    local parsed = url.parse(result.epub_href)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        return nil, "invalid protocol: " .. tostring(parsed and parsed.scheme)
    end

    -- "Author - Title.epub"; the acquisition mimetype already told us the
    -- format, so no extra server round-trip for a filename.
    local name = result.title or "download"
    if result.author then
        name = result.author .. " - " .. name
    end
    local filename = util.getSafeFilename(name .. ".epub", download_dir)
    local base = download_dir ~= "/" and download_dir or ""
    local local_path = base .. "/" .. filename

    if lfs.attributes(local_path, "mode") then
        local stem = filename:gsub("%.epub$", "")
        local candidate
        for i = 1, 99 do
            local with_suffix = string.format("%s/%s (%d).epub", base, stem, i)
            if not lfs.attributes(with_suffix, "mode") then
                candidate = with_suffix
                break
            end
        end
        if not candidate then
            return nil, "file already exists"
        end
        local_path = candidate
    end

    local file, io_err = io.open(local_path, "w")
    if not file then
        return nil, io_err or "cannot write to download folder"
    end

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{
        url = result.epub_href,
        headers = { ["Accept-Encoding"] = "identity" },
        sink = socketutil.file_sink(file), -- closes the handle on completion and on timeout
        user = server.username,
        password = server.password,
    })
    socketutil:reset_timeout()

    if code == 200 then
        return local_path
    end
    util.removeFile(local_path) -- drop the empty/partial file
    return nil, code and tostring(code) or "network unreachable"
end

return CatalogSearch
