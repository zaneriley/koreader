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
        if type(server.username) == "string" and server.username ~= ""
            and type(server.password) == "string" and server.password ~= ""
            and server.url then
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

function CatalogSearch:_withTimeout(block_timeout, total_timeout, fn)
    local socketutil = self:_dep("socketutil")
    socketutil:set_timeout(block_timeout, total_timeout)
    local ok, a, b, c, d = pcall(fn)
    socketutil:reset_timeout()
    if not ok then
        return nil, tostring(a)
    end
    return a, b, c, d
end

function CatalogSearch:_fetch(target_url, username, password)
    local http = self:_dep("http")
    local socket = self:_dep("socket")
    local sink_table = {}
    -- Tighter than stock OPDS (10s/30s): search is a passive fill-in, a dead
    -- server must not hang the UI. table_sink enforces the total cap.
    local code, request_err = self:_withTimeout(3, 5, function()
        return socket.skip(1, http.request{
            url = target_url,
            method = "GET",
            headers = { ["Accept-Encoding"] = "identity" },
            sink = self:_dep("socketutil").table_sink(sink_table),
            user = username,
            password = password,
        })
    end)
    if code == 200 then
        local body = table.concat(sink_table)
        if body ~= "" then
            return body
        end
        return nil, "empty response"
    end
    return nil, code and tostring(code) or request_err or "network unreachable"
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

function CatalogSearch:_itemsFromCatalog(catalog, result_url)
    local Browser = self:_dep("opds_browser")
    -- Throwaway pseudo-instance: genItemTableFromCatalog touches no Menu
    -- widget state, and sync = true makes it a pure feed->items transform
    -- (skips nested OpenSearch discovery and facet collection). Never call it
    -- on the class table itself: it mutates fields, and require caches the
    -- module shared with the real OPDS browser.
    local browser = Browser:extend{ sync = true }
    return browser:genItemTableFromCatalog(catalog, result_url), Browser
end

function CatalogSearch:_resultsFromCatalog(catalog, result_url)
    local items, Browser = self:_itemsFromCatalog(catalog, result_url)
    local url = self:_dep("url")
    local gettext = require("gettext")
    local results = {}
    local feed_hrefs = items and items.hrefs
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
            -- normalize opdsbrowser's localized placeholder strings back to
            -- nil so the UI's own missing-data paths apply, and download
            -- filenames degrade to the feed text instead of "Unknown"
            local title = item.title
            if title == gettext("Unknown") then title = nil end
            local author = item.author
            if author == gettext("Unknown Author") then author = nil end
            -- The book's identity is its ACQUISITION path (every result has
            -- one by construction): a URL path so it survives host/port
            -- changes, and never the thumbnail's — artwork can appear or
            -- vanish between fetches without re-keying the book. thumb_href
            -- is artwork only.
            local thumb = item.thumbnail or item.image
            local parsed = url.parse(epub.href)
            table.insert(results, {
                title = title or item.text,
                author = author,
                text = item.text,
                epub_href = epub.href, -- absolutized by genItemTableFromCatalog
                mimetype = epub.type,
                thumb_href = thumb,
                catalog_id = parsed and parsed.path or nil,
            })
        end
    end
    -- feed_hrefs carries the feed-level rel links (absolutized by the
    -- parser), e.g. hrefs.next when the catalog paginates
    return results, feed_hrefs
end

-- One page of a section feed: rows plus the "next" href when the catalog
-- paginates — for surfaces that browse a whole shelf rather than a rail
-- window. Returns { rows, next_href } | nil, err.
function CatalogSearch:railPage(server, page_href)
    local catalog, err = self:_fetchParsed(page_href, server)
    if not catalog then
        return nil, err
    end
    local rows, feed_hrefs = self:_resultsFromCatalog(catalog, page_href)
    return {
        rows = rows,
        next_href = feed_hrefs and feed_hrefs.next or nil,
    }
end

-- Raw image bytes for one result's thumb_href. Synchronous like download():
-- callers schedule it off the paint path. Returns bytes | nil, err.
function CatalogSearch:fetchThumbnail(server, thumb_href)
    if type(thumb_href) ~= "string" or thumb_href == "" then
        return nil, "no thumbnail"
    end
    return self:_fetch(thumb_href, server.username, server.password)
end

-- The Discover rails: the catalog's "recently added" and "hot" style
-- sections, matched by href path on the root feed (calibre-web: /opds/new
-- and /opds/hot). Title-blind so the server's language does not matter.
CatalogSearch.RAIL_PATHS = {
    new = "/new/?$",
    hot = "/hot/?$",
}

-- The reader's own collections (calibre-web: /opds/shelfindex), matched the
-- same href-path way.
CatalogSearch.SHELF_INDEX_PATH = "/shelfindex/?$"

-- Pure selection over an already-fetched sections list: the anchor rails
-- (new first, then hot) and the shelf-index section when the catalog has
-- one. The Discover surface drives its fetches one per UI pass and calls
-- this between them; discoverRails composes the whole plan for callers
-- that can afford both fetches at once.
function CatalogSearch:railPlan(sections)
    local url = self:_dep("url")
    local anchors = {}
    local shelf_index
    for _i, section in ipairs(sections or {}) do
        local parsed = url.parse(section.href) or {}
        local path = parsed.path or ""
        for key, pattern in pairs(self.RAIL_PATHS) do
            if not anchors[key] and path:match(pattern) then
                anchors[key] = section
            end
        end
        if not shelf_index and path:match(self.SHELF_INDEX_PATH) then
            shelf_index = section
        end
    end
    if not (anchors.new or anchors.hot) then
        return nil, "catalog has no discover sections"
    end
    local rails = {}
    for _i, key in ipairs({ "new", "hot" }) do
        local section = anchors[key]
        if section then
            table.insert(rails, { key = key, title = section.title, href = section.href })
        end
    end
    return { rails = rails, shelf_index = shelf_index }
end

-- Returns the ordered rail plan for the Discover surface: the two anchor
-- sections first (new, hot), then one rail per custom shelf in catalog
-- order. Each rail is { key, title, href }; shelf keys embed the shelf's
-- href path so they stay stable across hosts. Shelf discovery is best
-- effort: a catalog without shelves (or a failing shelf index) still
-- yields the anchor rails.
function CatalogSearch:discoverRails(server)
    local sections, err = self:sections(server)
    if not sections then
        return nil, err
    end
    local plan, plan_err = self:railPlan(sections)
    if not plan then
        return nil, plan_err
    end
    local rails = plan.rails
    for _i, shelf in ipairs(self:shelves(server, plan.shelf_index)) do
        table.insert(rails, shelf)
    end
    return rails
end

-- Lists the catalog's custom shelves from its shelf index feed.
-- calibre-web decorates public shelf titles with a "(Public)" marker —
-- server metadata, not the shelf's name, so one trailing marker is
-- stripped. The marker is gettext-localized server-side, so this only
-- covers English-locale servers; other locales keep it (cosmetic only).
function CatalogSearch:shelves(server, shelf_index_section)
    if not shelf_index_section then
        return {}
    end
    local catalog = self:_fetchParsed(shelf_index_section.href, server)
    if not catalog then
        return {} -- degraded, not fatal: the anchor rails still stand
    end
    local url = self:_dep("url")
    local shelves = {}
    for _i, item in ipairs(self:_itemsFromCatalog(catalog, shelf_index_section.href) or {}) do
        local title = item.text or item.title
        if item.url and type(title) == "string" then
            title = title:gsub("%s*%(Public%)%s*$", "")
            if title ~= "" then
                local path = (url.parse(item.url) or {}).path or item.url
                table.insert(shelves, {
                    key = "shelf:" .. path,
                    title = title,
                    href = item.url,
                })
            end
        end
    end
    return shelves
end

-- Lists the catalog's navigation sections (title + absolute href) from the
-- root feed — e.g. calibre-web's Recently added / Hot / Top Rated rows.
-- Discover picks its rails out of these instead of hardcoding server paths.
function CatalogSearch:sections(server)
    local catalog, err = self:_fetchParsed(server.url, server)
    if not catalog then
        return nil, err
    end
    local items = self:_itemsFromCatalog(catalog, server.url)
    local sections = {}
    for _, item in ipairs(items or {}) do
        if item.url then
            table.insert(sections, {
                title = item.text or item.title,
                href = item.url,
            })
        end
    end
    return sections
end

-- Fetches one section feed and returns its epub results, same shape as
-- search results.
function CatalogSearch:rail(server, section_href)
    local catalog, err = self:_fetchParsed(section_href, server)
    if not catalog then
        return nil, err
    end
    -- single value: the feed-level hrefs stay internal to railPage
    local results = self:_resultsFromCatalog(catalog, section_href)
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
    local results = self:_resultsFromCatalog(catalog, search_url)
    return results
end

-- Downloads one search result's EPUB into the shelf's download dir.
-- Returns local_path on success; nil, err on failure. Synchronous: the
-- caller paints its "Downloading..." beat first and schedules this after.
function CatalogSearch:download(server, result, opts)
    opts = opts or {}
    local lfs = self:_dep("lfs")
    local util = self:_dep("util")
    local url = self:_dep("url")
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

    local temp_path = local_path .. ".part"
    util.removeFile(temp_path)
    local file, io_err = io.open(temp_path, "w")
    if not file then
        return nil, io_err or "cannot write to download folder"
    end

    local socketutil = self:_dep("socketutil")
    local code, request_err = self:_withTimeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT, function()
        return socket.skip(1, http.request{
            url = result.epub_href,
            headers = { ["Accept-Encoding"] = "identity" },
            sink = socketutil.file_sink(file), -- closes the handle on completion and on timeout
            user = server.username,
            password = server.password,
        })
    end)
    pcall(function() file:close() end)

    if code == 200 then
        local renamed, rename_err = os.rename(temp_path, local_path)
        if not renamed then
            util.removeFile(temp_path)
            return nil, rename_err or "cannot move downloaded file into place"
        end
        return local_path
    end
    util.removeFile(temp_path) -- drop the empty/partial file
    return nil, code and tostring(code) or request_err or "network unreachable"
end

return CatalogSearch
