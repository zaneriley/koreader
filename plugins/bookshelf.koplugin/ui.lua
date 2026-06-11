local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Math = require("optmath")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local Screen = Device.screen
local T = ffiUtil.template

local source = debug.getinfo(1, "S").source or ""
local plugin_dir = source:match("^@(.+)/[^/]+$") or "plugins/bookshelf.koplugin"
local GridLayout = dofile(plugin_dir .. "/gridlayout.lua")
local Icons = dofile(plugin_dir .. "/icons.lua")

-- Prefer the chosen reading face for the shelf's serif voice when it is
-- installed (user fonts dir), so the library home matches the book pages;
-- degrade to the bundled face otherwise.
local function resolveFace(preferred, fallback)
    local ok, face = pcall(Font.getFace, Font, preferred, 16)
    if ok and face then
        return preferred
    end
    return fallback
end

local serif_face = resolveFace("SourceSerif4SmText-Regular.ttf", "NotoSerif-Regular.ttf")
local serif_italic_face = resolveFace("SourceSerif4SmText-It.ttf", "NotoSerif-Italic.ttf")

local FontTokens = {
    display = serif_face,
    display_italic = serif_italic_face,
    serif_safe = serif_face,
    sans = "NotoSans-Regular.ttf",
    sans_bold = "NotoSans-Bold.ttf",
}

local TypeScale = {
    card_meta = 10,
    card_title = 12,
    category = 13,
    hero_title = 20,
    page_title = 38,
}

-- Spacing ladder: every gap in the shelf system is one of these steps.
local Space = {
    xs = 4,
    s = 8,
    m = 12,
    l = 16,
    xl = 24,
}

-- Rail grammar: a half cover sliced at the edge means "more books, swipe".
-- Recently added shows a chosen count; all books shows what the width fits.
local RailTokens = {
    peek = 0.5,
    recent_full_count = 6,
}

-- Book panel cover box (dialog domain: DPI-scaled via scaleBySize, not
-- shelf_scale) — 2:3, sized between the small and large card covers
local PanelTokens = {
    cover_w = 132,
    cover_h = 184,
}

-- All-books view preferences. Sort keys map onto the provider's sort
-- fields; status keys onto the provider's record.status values.
local SORT_OPTIONS = {
    { key = "recent", label = _("Recent") },
    { key = "title", label = _("Title") },
    { key = "authors", label = _("Author") },
}
local STATUS_OPTIONS = {
    { key = "all", label = _("All") },
    { key = "reading", label = _("Reading") },
    { key = "new", label = _("Unread") },
    { key = "complete", label = _("Finished") },
}
-- display names for the language filter; unknown tags show as-is
local LANGUAGE_NAMES = {
    en = _("English"),
    ja = "日本語",
}

local IconTokens = {
    visual = 24,
    tap = 40,
}

local LayoutTokens = {
    page_top = 16,
    status_to_title = 32,
    title_block = 72,
    title_to_shelves = 24,
    category_header = 32,
    shelf_body_gap = 12,
    continue_to_lower_gap = 32,
    lower_shelf_gap = 32,
    lower_bottom_margin = 16, -- unscaled_size_check: ignore
    empty_home_offset = 64,
}

local BookTextTokens = {
    title_max_lines = 2,
    title_line_height = 0.12,
    metadata_line_height = 0.02,
}

local function scale(n)
    return Screen:scaleBySize(n)
end

local function clampWidth(width)
    return math.max(scale(8), math.floor(width or 0))
end

local function clampPercent(value)
    value = tonumber(value) or 0
    if value < 0 then
        return 0
    elseif value > 1 then
        return 1
    end
    return value
end

local function entriesWindow(entries, first, count)
    local window = {}
    for i = 0, math.max(0, count or 0) - 1 do
        window[#window + 1] = entries[first + i]
    end
    return window
end

local LibraryUI = InputContainer:extend{
    title = _("Library"),
    is_borderless = true,
    zones = nil,
    rail_regions = nil,
    rail_state = nil,
    library_page = 1,
    pressed_zone_id = nil,
}

-- Exposed for specs: face resolution depends on which fonts are installed.
LibraryUI._font_tokens = FontTokens

function LibraryUI:_triggerBackgroundExtraction()
    local manager = self:_bookInfoManager()
    if not manager then return end

    local cover_specs = self:_coverSpecs()
    local to_extract = {}
    local entries = self:_libraryEntries()
    for _, entry in ipairs(entries) do
        local file = self:_entryFile(entry)
        if file then
            local ok, bookinfo = pcall(manager.getBookInfo, manager, file, false)
            local should_extract = false
            if not ok or type(bookinfo) ~= "table" then
                should_extract = true
            elseif tonumber(bookinfo.in_progress) and tonumber(bookinfo.in_progress) > 0 then
                should_extract = false
            elseif not bookinfo.ignore_cover then
                if not bookinfo.cover_fetched then
                    should_extract = true
                elseif bookinfo.has_cover and manager.isCachedCoverInvalid
                    and manager.isCachedCoverInvalid(bookinfo, cover_specs) then
                    should_extract = true
                end
            end
            if should_extract then
                table.insert(to_extract, { filepath = file, cover_specs = cover_specs })
            end
        end
    end

    if #to_extract > 0 then
        logger.info("Bookshelf triggering background extraction for", #to_extract, "books")
        UIManager:nextTick(function()
            local launched = manager:extractInBackground(to_extract)
            if launched then
                self:_scheduleCoverCacheRetry()
            end
        end)
    end
end

function LibraryUI:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.rail_regions = self.rail_regions or {}
    self.rail_state = self.rail_state or {}
    self.library_page = self.library_page or 1
    self.ges_events.Tap = {
        GestureRange:new{
            ges = "tap",
            range = self.dimen,
        },
    }
    self.ges_events.Swipe = {
        GestureRange:new{
            ges = "swipe",
            range = self.dimen,
        },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:_triggerBackgroundExtraction()
end

function LibraryUI:closeBookshelf(refresh_type)
    if self._closed then
        return
    end
    self._closed = true
    self:_freeCoverCache()
    UIManager:close(self, refresh_type)
    if self.closed_callback then
        self.closed_callback()
    end
end

function LibraryUI:onClose()
    self:closeBookshelf()
    return true
end

function LibraryUI:onCloseAllMenus()
    self:closeBookshelf()
    return true
end

function LibraryUI:onShowingReader()
    self:closeBookshelf("full")
    return true
end

function LibraryUI:onShowFileManager()
    self:closeBookshelf("full")
    -- Let the explicit File browser event continue to the Reader/FileManager
    -- underneath. Library is only an overlay participant here.
    return false
end

function LibraryUI:_providerOptions()
    return {
        ui = self.ui,
    }
end

function LibraryUI:_providerCall(method, ...)
    if type(self.provider) ~= "table" or type(self.provider[method]) ~= "function" then
        return nil
    end

    local fn = self.provider[method]
    local ok, result = pcall(fn, self:_providerOptions(), ...)
    if ok and result ~= nil then
        return result
    elseif not ok then
        logger.warn("Bookshelf provider static call failed:", method, result)
    end

    ok, result = pcall(fn, self.provider, self:_providerOptions(), ...)
    if ok then
        return result
    end
    logger.warn("Bookshelf provider method failed:", method, result)
    return nil
end

function LibraryUI:_libraryCache()
    self._library_cache = self._library_cache or {}
    return self._library_cache
end

function LibraryUI:_invalidateLibraryCache()
    self._library_cache = {}
end

function LibraryUI:_providerList(...)
    local result
    for _, method in ipairs({...}) do
        result = self:_providerCall(method)
        if type(result) == "table" then
            break
        end
    end
    if type(result) ~= "table" then
        return {}
    end
    if type(result.items) == "table" then
        result = result.items
    end
    if type(result[1]) == "nil" then
        return {}
    end
    return result
end

function LibraryUI:_providerEntry(...)
    for _, method in ipairs({...}) do
        local result = self:_providerCall(method)
        if type(result) == "table" then
            return result
        end
    end
    return nil
end

function LibraryUI:_fileName(file)
    if type(file) ~= "string" or file == "" then
        return nil
    end
    local path, name = util.splitFilePathName(file) -- luacheck: no unused
    return BD.filename(name)
end

function LibraryUI:_entryFile(entry)
    if type(entry) ~= "table" then
        return nil
    end
    return entry.file or entry.path or entry.filepath
end

function LibraryUI:_cleanDisplayTitle(title)
    if type(title) ~= "string" or title == "" then
        return nil
    end
    title = title:gsub("^%s+", ""):gsub("%s+$", "")
    if title:lower():match("^quickstart[%s%-_]") then
        return _("Quickstart Guide")
    end
    return BD.auto(title)
end

function LibraryUI:_fileTitle(file)
    if type(file) ~= "string" or file == "" then
        return nil
    end
    local title = filemanagerutil.splitFileNameType(file)
    if type(title) ~= "string" or title == "" then
        return self:_fileName(file)
    end
    title = title:gsub("[_-]+", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if title:lower():match("^quickstart%s+") then
        title = _("Quickstart Guide")
    end
    return BD.filename(title)
end

function LibraryUI:_entryTitle(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local title = self:_cleanDisplayTitle(entry.display_title)
        or self:_cleanDisplayTitle(entry.title)
        or self:_cleanDisplayTitle(entry.text)
        or self:_cleanDisplayTitle(entry.name)
    if title then
        return title
    end
    return self:_fileTitle(entry.file or entry.path)
end

local function joinAuthorLines(value)
    if type(value) ~= "string" then
        return value
    end
    return (value:gsub("%s*\n%s*", ", "))
end

function LibraryUI:_entryAuthor(entry)
    if type(entry) ~= "table" then
        return nil
    end
    return self:_cleanDisplayTitle(joinAuthorLines(entry.authors))
        or self:_cleanDisplayTitle(joinAuthorLines(entry.author))
        or self:_cleanDisplayTitle(entry.subtitle)
        or self:_cleanDisplayTitle(entry.series)
end

function LibraryUI:_currentFile()
    local document = self.ui and self.ui.document
    return document and document.file
end

function LibraryUI:_isCurrentFile(file)
    return type(file) == "string" and file ~= "" and file == self:_currentFile()
end

function LibraryUI:_currentPageInfo()
    local current_page
    if self.ui and type(self.ui.getCurrentPage) == "function" then
        local ok, page = pcall(self.ui.getCurrentPage, self.ui)
        if ok then
            current_page = page
        end
    end

    local page_count
    local document = self.ui and self.ui.document
    if document and type(document.getPageCount) == "function" then
        local ok, count = pcall(document.getPageCount, document)
        if ok then
            page_count = count
        end
    end

    return tonumber(current_page), tonumber(page_count)
end

function LibraryUI:_currentPercentFinished()
    local footer = self.ui and self.ui.view and self.ui.view.footer
    if footer and footer.percent_finished then
        return clampPercent(footer.percent_finished)
    end
    local doc_settings = self.ui and self.ui.doc_settings
    if doc_settings and type(doc_settings.readSetting) == "function" then
        return clampPercent(doc_settings:readSetting("percent_finished"))
    end
    return 0
end

function LibraryUI:_normalizeContinueEntry(entry)
    if type(entry) ~= "table" then
        return nil
    end
    local file = entry.file or entry.path
    if not entry.current and self:_isCurrentFile(file) then
        entry = util.tableDeepCopy(entry)
        entry.current = true
        entry.mandatory = _("Reading")
    elseif file and lfs.attributes(file, "mode") ~= "file" then
        -- a removed book must not keep advertising itself as the hero
        return nil
    end
    return entry
end

function LibraryUI:_currentDocumentEntry()
    local file = self:_currentFile()
    if not file then
        return nil
    end
    local doc_props = self.ui and self.ui.doc_props or {}
    local current_page, page_count = self:_currentPageInfo()
    return {
        text = self:_cleanDisplayTitle(doc_props.display_title)
            or self:_cleanDisplayTitle(doc_props.title)
            or self:_fileTitle(file)
            or _("Current book"),
        file = file,
        current = true,
        mandatory = _("Reading"),
        percent_finished = self:_currentPercentFinished(),
        current_page = current_page,
        pages = page_count,
        authors = self:_cleanDisplayTitle(doc_props.authors),
    }
end

function LibraryUI:_lastFileEntry()
    local file = G_reader_settings:readSetting("lastfile")
    if not file or lfs.attributes(file, "mode") ~= "file" then
        return nil
    end
    return {
        text = self:_fileTitle(file) or _("Last book"),
        file = file,
        mandatory = _("Last"),
    }
end

function LibraryUI:_continueEntry()
    local cache = self:_libraryCache()
    if cache.continue_entry ~= nil then
        return cache.continue_entry or nil
    end
    local entry = self:_normalizeContinueEntry(self:_providerEntry("getContinue", "getContinueItem", "getLastReading"))
        or self:_currentDocumentEntry()
        or self:_lastFileEntry()
    cache.continue_entry = entry or false
    return entry
end

function LibraryUI:_downloadedEntries()
    local cache = self:_libraryCache()
    if cache.downloaded_entries then
        return cache.downloaded_entries
    end
    cache.downloaded_entries = self:_providerList("getDownloaded", "getDownloadedItems", "getDownloadedBooks")
    return cache.downloaded_entries
end

function LibraryUI:_uniqueEntries(entries)
    local unique = {}
    local seen = {}
    for _, entry in ipairs(entries) do
        local key = entry.id or entry.file or entry.path or self:_entryTitle(entry)
        if key and not seen[key] then
            seen[key] = true
            table.insert(unique, entry)
        end
    end
    return unique
end

function LibraryUI:_libraryEntries()
    local cache = self:_libraryCache()
    if cache.library_entries then
        return cache.library_entries
    end
    local entries = {}
    local continue = self:_continueEntry()
    if continue then
        table.insert(entries, continue)
    end
    for _, entry in ipairs(self:_downloadedEntries()) do
        table.insert(entries, entry)
    end
    entries = self:_uniqueEntries(entries)
    cache.library_entries = entries
    return entries
end

function LibraryUI:_recentlyAddedEntries()
    local cache = self:_libraryCache()
    if cache.recently_added_entries then
        return cache.recently_added_entries
    end
    local entries = self:_providerList("getRecentlyAdded", "getRecentBooks", "getNewBooks")
    if #entries == 0 then
        entries = self:_libraryEntries()
    end
    cache.recently_added_entries = entries
    return entries
end

function LibraryUI:_dictionary()
    if not self.ui then
        return nil
    end
    if self.ui.dictionary then
        return self.ui.dictionary
    end
    if type(self.ui.getDictionary) == "function" then
        return self.ui:getDictionary()
    end
    return nil
end

function LibraryUI:_showInfo(text)
    UIManager:show(InfoMessage:new{
        text = text,
    })
end

function LibraryUI:_searchLibraryEntries(query)
    query = type(query) == "string" and query:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
    if query == "" then
        return {}
    end
    local results = {}
    for _, entry in ipairs(self:_libraryEntries()) do
        local title = (self:_entryTitle(entry) or ""):lower()
        local author = (self:_entryAuthor(entry) or ""):lower()
        if title:find(query, 1, true) or author:find(query, 1, true) then
            table.insert(results, entry)
        end
    end
    return results
end

function LibraryUI:_showLibrarySearch()
    -- The header search icon searches the LIBRARY (device first, catalog
    -- async), never the dictionary; dictionary lookup stays on its nav tab.
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Search library"),
        input = "",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)
                    if type(query) == "string" and query:gsub("%s", "") ~= "" then
                        self:_runLibrarySearch(query)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function LibraryUI:_runLibrarySearch(query)
    local Menu = require("ui/widget/menu")
    local NetworkMgr = require("ui/network/manager")
    local CatalogSearch = dofile(plugin_dir .. "/catalogsearch.lua")
    self._catalog_search = self._catalog_search or CatalogSearch.new()
    local cs = self._catalog_search
    local server = cs:available() and cs:getServer() or nil

    -- Device results paint instantly; the catalog section fills in after.
    local unknown_label = _("Unknown")
    local item_table = {}
    for _, entry in ipairs(self:_searchLibraryEntries(query)) do
        table.insert(item_table, {
            text = self:_entryTitle(entry) or unknown_label,
            mandatory = self:_entryAuthor(entry),
            entry = entry,
        })
    end
    if #item_table == 0 then
        table.insert(item_table, {
            text = _("No matches on this device"),
            dim = true,
            select_enabled = false,
        })
    end
    if server then
        table.insert(item_table, {
            text = _("In your library"),
            bold = true,
            select_enabled = false,
        })
        table.insert(item_table, {
            text = _("Searching your library…"),
            dim = true,
            select_enabled = false,
        })
    end

    local menu, pending
    menu = Menu:new{
        title = T(_("Search: %1"), query),
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuChoice = function(_menu, item)
            if item.entry then
                self:_openEntry(item.entry)
            elseif item.remote then
                NetworkMgr:runWhenConnected(function()
                    UIManager:show(InfoMessage:new{ text = _("Downloading…"), timeout = 1 })
                    UIManager:scheduleIn(1, function()
                        local path, err = cs:download(server, item.remote)
                        if path then
                            if self.plugin and item.remote.catalog_id then
                                self.plugin:recordDownload(item.remote.catalog_id, path)
                            end
                            if not self._closed then
                                self:_invalidateLibraryCache()
                                self:_triggerBackgroundExtraction()
                                UIManager:setDirty(self, "ui", self.dimen)
                            end
                        else
                            self:_showInfo(T(_("Download failed: %1"), err))
                        end
                    end)
                end)
            end
        end,
        close_callback = function()
            menu._closed = true
            if pending then
                UIManager:unschedule(pending)
            end
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)

    if server then
        NetworkMgr:runWhenConnected(function()
            pending = UIManager:tickAfterNext(function()
                -- the menu's local rows have painted by now; the fetch below
                -- blocks briefly (3s connect / 5s total caps)
                if menu._closed or not UIManager:isWidgetShown(menu) then
                    return
                end
                local results, err = cs:search(server, query)
                if menu._closed then
                    return -- taps were queued during the block
                end
                local download_label = _("Download")
                local items = menu.item_table
                items[#items] = nil -- the "Searching…" placeholder is last by construction
                if results and #results > 0 then
                    for _, row in ipairs(results) do
                        table.insert(items, {
                            text = row.text or row.title,
                            mandatory = download_label,
                            remote = row,
                        })
                    end
                else
                    table.insert(items, {
                        text = err and _("Library unavailable") or _("No matches in your library"),
                        dim = true,
                        select_enabled = false,
                    })
                end
                menu:switchItemTable(nil, items, -1)
            end)
        end)
    end
end

function LibraryUI:_showDictionaryLookup()
    local dictionary = self:_dictionary()
    if dictionary and type(dictionary.onShowDictionaryLookup) == "function" then
        dictionary:onShowDictionaryLookup()
        return
    end

    self:_showInfo(_("Dictionary lookup is unavailable."))
end

-- the primary language subtag: "en-US" -> "en", "ja" -> "ja"
local function languageTag(value)
    if type(value) ~= "string" then
        return nil
    end
    return value:lower():match("^%a%a%a?")
end

function LibraryUI:_uiPref(key, fallback)
    local value = self.plugin and self.plugin:uiPref(key)
    if value == nil then
        return fallback
    end
    return value
end

function LibraryUI:_saveUiPref(key, value)
    if self.plugin then
        self.plugin:saveUiPref(key, value)
    end
    self:_invalidateLibraryCache()
    UIManager:setDirty(self, "ui", self.dimen)
end

function LibraryUI:_librarySortKey()
    local key = self:_uiPref("library_sort", "recent")
    for _i, option in ipairs(SORT_OPTIONS) do
        if option.key == key then
            return key, option.label
        end
    end
    return "recent", SORT_OPTIONS[1].label
end

-- In-place view sort over the provider's precomputed sort fields, with
-- display-field fallbacks for entries that did not come from the provider
-- (e.g. the continue entry). "recent" keeps the provider's order.
function LibraryUI:_applyLibrarySort(entries, key)
    if key == "recent" then
        return entries
    end
    -- raw fields only: _entryTitle/_entryAuthor return DISPLAY strings
    -- (BiDi-isolate wrapped), whose control bytes sort after every letter
    local function titleKey(entry)
        if entry.sort_title then
            return entry.sort_title
        end
        local raw = entry.display_title or entry.title or entry.text or entry.name
        return type(raw) == "string" and raw:lower() or ""
    end
    local function authorKey(entry)
        if entry.sort_authors then
            return entry.sort_authors
        end
        local raw = entry.authors or entry.author
        return type(raw) == "string" and raw:lower() or ""
    end
    if key == "title" then
        table.sort(entries, function(a, b)
            local ta, tb = titleKey(a), titleKey(b)
            if ta ~= tb then
                return ta < tb
            end
            return authorKey(a) < authorKey(b)
        end)
    elseif key == "authors" then
        table.sort(entries, function(a, b)
            local aa, ab = authorKey(a), authorKey(b)
            if aa ~= ab then
                -- authorless entries sort last, not first
                if aa == "" or ab == "" then
                    return ab == ""
                end
                return aa < ab
            end
            return titleKey(a) < titleKey(b)
        end)
    end
    return entries
end

function LibraryUI:_entryMatchesFilter(entry, status_key, language_key)
    if status_key and status_key ~= "all" then
        if (entry.status or "new") ~= status_key then
            return false
        end
    end
    if language_key and language_key ~= "all" then
        if languageTag(entry.language) ~= language_key then
            return false
        end
    end
    return true
end

-- The All books shelf's view: the library filtered and sorted per the
-- persisted preferences. Search and the other shelves stay unfiltered.
function LibraryUI:_allBooksEntries()
    local cache = self:_libraryCache()
    if cache.all_books_entries then
        return cache.all_books_entries
    end
    local status_key = self:_uiPref("library_filter_status", "all")
    local language_key = self:_uiPref("library_filter_language", "all")
    local entries = {}
    for _i, entry in ipairs(self:_libraryEntries()) do
        if self:_entryMatchesFilter(entry, status_key, language_key) then
            table.insert(entries, entry)
        end
    end
    self:_applyLibrarySort(entries, (self:_librarySortKey()))
    cache.all_books_entries = entries
    return entries
end

-- distinct language tags across the library, for the filter dialog
function LibraryUI:_libraryLanguages()
    local seen, tags = {}, {}
    for _i, entry in ipairs(self:_libraryEntries()) do
        local tag = languageTag(entry.language)
        if tag and not seen[tag] then
            seen[tag] = true
            table.insert(tags, tag)
        end
    end
    table.sort(tags)
    return tags
end

-- The language rows for the filter dialog. A saved filter must always be
-- visible and resettable here — even when no book on the device carries
-- its tag any more — or a stale pref strands All books at "0 of N" with
-- no in-UI way out.
function LibraryUI:_languageFilterChoices()
    local languages = self:_libraryLanguages()
    local current = self:_uiPref("library_filter_language", "all")
    if #languages == 0 and current == "all" then
        return {} -- nothing to filter by and nothing active: no section
    end
    local choices = {
        { key = "all", label = _("All languages"), selected = current == "all" },
    }
    local has_current = current == "all"
    for _i, tag in ipairs(languages) do
        table.insert(choices, {
            key = tag,
            label = LANGUAGE_NAMES[tag] or tag,
            selected = tag == current,
        })
        if tag == current then
            has_current = true
        end
    end
    if not has_current then
        -- the active filter's language is absent from the device library:
        -- show it anyway, checkmarked, so the empty shelf explains itself
        table.insert(choices, {
            key = current,
            label = LANGUAGE_NAMES[current] or current,
            selected = true,
        })
    end
    return choices
end

local function choiceLabel(selected, label)
    -- trailing checkmark, the stock dialog convention
    return selected and (label .. "  ✓") or label
end

function LibraryUI:_showSortDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local current = self:_librarySortKey()
    local dialog
    local buttons = {}
    for _i, option in ipairs(SORT_OPTIONS) do
        table.insert(buttons, {{
            text = choiceLabel(option.key == current, option.label),
            callback = function()
                UIManager:close(dialog)
                self:_saveUiPref("library_sort", option.key)
            end,
        }})
    end
    dialog = ButtonDialog:new{
        width_factor = 0.6,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function LibraryUI:_showFilter()
    local ButtonDialog = require("ui/widget/buttondialog")
    local status_current = self:_uiPref("library_filter_status", "all")
    local dialog
    local buttons = {}
    for _i, option in ipairs(STATUS_OPTIONS) do
        table.insert(buttons, {{
            text = choiceLabel(option.key == status_current, option.label),
            callback = function()
                UIManager:close(dialog)
                self:_saveUiPref("library_filter_status", option.key)
            end,
        }})
    end
    local choices = self:_languageFilterChoices()
    if #choices > 0 then
        table.insert(buttons, {}) -- separator: status above, language below
        for _i, choice in ipairs(choices) do
            local key = choice.key
            table.insert(buttons, {{
                text = choiceLabel(choice.selected, choice.label),
                callback = function()
                    UIManager:close(dialog)
                    self:_saveUiPref("library_filter_language", key)
                end,
            }})
        end
    end
    dialog = ButtonDialog:new{
        width_factor = 0.6,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- The library-level actions behind the page header's kebab. Real actions
-- only: refresh re-derives the shelves and kicks cover extraction; the
-- catalog manager is the stock OPDS server UI — the on-device way to set
-- the server address and credentials.
function LibraryUI:_showMore()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        width_factor = 0.6,
        buttons = {
            {{
                text = _("Refresh library"),
                callback = function()
                    UIManager:close(dialog)
                    self:_refreshLibrary()
                end,
            }},
            {{
                text = _("Manage catalog"),
                callback = function()
                    UIManager:close(dialog)
                    self:_addBooks()
                end,
            }},
        },
    }
    UIManager:show(dialog)
end

function LibraryUI:_refreshLibrary()
    self:_invalidateLibraryCache()
    self:_triggerBackgroundExtraction()
    UIManager:setDirty(self, "ui", self.dimen)
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{ text = _("Library refreshed") })
end

function LibraryUI:_showFiles(path)
    local FileManager = require("apps/filemanager/filemanager")
    if self.ui and self.ui.file_chooser then
        local filemanager_path = path or self.ui.file_chooser.path
        if filemanager_path and lfs.attributes(filemanager_path, "mode") == "file" then
            filemanager_path = util.splitFilePathName(filemanager_path)
        end
        if FileManager.instance == self.ui and type(self.ui.onClose) == "function" then
            self.ui:onClose()
        end
        FileManager:showFiles(filemanager_path)
        if FileManager.instance then
            FileManager.instance.return_to_previous_view = true
        end
        return
    end

    if path and lfs.attributes(path, "mode") == "directory" then
        FileManager:showFiles(path)
    elseif self.ui and type(self.ui.showFileManager) == "function" then
        self.ui:showFileManager(path)
    else
        FileManager:showFiles(path)
    end

    if FileManager.instance then
        FileManager.instance.return_to_previous_view = true
    end
end

function LibraryUI:_openEntry(entry)
    if type(entry) ~= "table" then
        return
    end
    if type(entry.callback) == "function" then
        local ok, err = pcall(entry.callback, entry, self)
        if not ok then
            logger.warn("Bookshelf entry callback failed:", err)
            self:_showInfo(_("This book could not be opened."))
        end
        return
    end

    local file = entry.file or entry.path
    if type(file) ~= "string" or file == "" then
        self:_showInfo(_("This book has no file to open."))
        return
    end

    local mode = lfs.attributes(file, "mode")
    if mode == "directory" then
        self:_showFiles(file)
    elseif mode == "file" then
        filemanagerutil.openFile(self.ui, file, function()
            self:closeBookshelf("full")
        end)
    else
        self:_showInfo(T(_("Book not found: %1"), BD.filepath(file)))
    end
end

function LibraryUI:_continue()
    local entry = self:_continueEntry()
    if not entry then
        return true
    elseif entry.current then
        self:closeBookshelf("full")
    else
        self:_openEntry(entry)
    end
end

-- The book's local file, verified: catalog entries resolve through the
-- live download map (which re-stats), local entries stat their own file —
-- a stale card never offers actions for a book that is already gone.
function LibraryUI:_entryLocalPath(entry)
    if entry.catalog_id and self.plugin then
        local path = self.plugin:downloadedPath(entry.catalog_id)
        if path then
            return path
        end
    end
    local file = entry.file or entry.path
    if type(file) == "string" and lfs.attributes(file, "mode") == "file" then
        return file
    end
end

-- The book panel: every card kebab's destination, and the tap target on
-- catalog surfaces. One component, actions by state: remote books offer
-- Read now / Add to device; on-device catalog-linked books offer Remove
-- from device; sideloaded books offer the stock permanent Delete.
function LibraryUI:_showBookPanel(entry)
    local ButtonDialog = require("ui/widget/buttondialog")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local Size = require("ui/size")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")

    local local_path = self:_entryLocalPath(entry)
    local reading = entry.current or entry.status == "reading"

    local dialog
    local buttons = {
        {{
            text = reading and _("Continue reading") or _("Read now"),
            callback = function()
                UIManager:close(dialog)
                if entry.current then
                    -- the book is already open beneath the bookshelf
                    self:closeBookshelf("full")
                elseif local_path then
                    self:_openEntry({ file = local_path })
                elseif entry.catalog_id and self._downloadEntry then
                    self:_downloadEntry(entry, function(path)
                        self:_openEntry({ file = path })
                    end)
                else
                    self:_showInfo(T(_("Book not found: %1"),
                        BD.filepath(entry.file or entry.path or "?")))
                end
            end,
        }},
    }
    if not local_path and entry.catalog_id and self._downloadEntry then
        table.insert(buttons, {{
            text = _("Add to device"),
            callback = function()
                UIManager:close(dialog)
                self:_downloadEntry(entry)
            end,
        }})
    end
    if local_path then
        -- linkage, not membership: the download map records what this
        -- plugin fetched; anything else (including stock-OPDS downloads
        -- from the same server) gets the honest permanent-delete flow
        local catalog_id = entry.catalog_id
        if not (catalog_id and self.plugin and self.plugin:downloadedPath(catalog_id)) then
            catalog_id = self.plugin and self.plugin:catalogIdForFile(local_path) or nil
        end
        table.insert(buttons, {}) -- separator: removal never neighbors reading
        if catalog_id then
            table.insert(buttons, {{
                text = _("Remove from device"),
                enabled = not entry.current,
                callback = function()
                    UIManager:close(dialog)
                    self:_confirmRemoveFromDevice(entry, catalog_id)
                end,
            }})
        else
            table.insert(buttons, {{
                text = _("Delete"),
                enabled = not entry.current,
                callback = function()
                    UIManager:close(dialog)
                    self:_confirmDeleteLocal(entry, local_path)
                end,
            }})
        end
    end

    dialog = ButtonDialog:new{
        width_factor = 0.8,
        buttons = buttons,
    }

    local avail_w = dialog:getAddedWidgetAvailableWidth()
    local box_w = Screen:scaleBySize(PanelTokens.cover_w)
    local box_h = Screen:scaleBySize(PanelTokens.cover_h)
    local cover = self:_cachedCoverFor(entry, box_w, box_h)
    if not cover and entry.catalog_id then
        -- serve the rail-size bb instead of queueing a second fetch for the
        -- panel-size key; in a 0.8-width dialog the size difference is fine
        local prefix = "catalog:" .. entry.catalog_id .. "|"
        for key, value in pairs(self.cover_cache or {}) do
            if type(value) == "table" and key:sub(1, #prefix) == prefix then
                cover = value
                break
            end
        end
    end
    local cover_widget = cover and ImageWidget:new{
        image = cover.bb,
        image_disposable = false, -- the bb belongs to cover_cache
        width = cover.w,
        height = cover.h,
    } or nil
    local text_w = avail_w - (cover and (cover.w + Size.padding.large) or 0)
    local text_col = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = self:_entryTitle(entry) or _("Untitled"),
            face = Font:getFace("smalltfont"),
            width = text_w,
        },
        VerticalSpan:new{ width = Size.padding.small },
        TextBoxWidget:new{
            text = self:_entryAuthor(entry) or "",
            face = Font:getFace("smallinfofont"),
            width = text_w,
        },
    }
    local header = HorizontalGroup:new{
        align = "top",
        not_focusable = true, -- dpad focus stays on the buttons
        parent = dialog,      -- survives reinit's free pass
    }
    if cover_widget then
        table.insert(header, cover_widget)
        table.insert(header, HorizontalSpan:new{ width = Size.padding.large })
    end
    table.insert(header, text_col)

    dialog:addWidget(header) -- exactly one addWidget call
    UIManager:show(dialog)
end

function LibraryUI:_confirmRemoveFromDevice(entry, catalog_id)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        -- every clause is plugin-verifiable: the file action, and the kept
        -- sidecar. No promises about the server or re-downloading.
        text = T(_("Remove \"%1\" from this device?\n\nThe downloaded file will be removed. Reading progress stays on this device."),
            self:_entryTitle(entry) or _("Untitled")),
        ok_text = _("Remove"),
        ok_callback = function()
            local path = self.plugin and self.plugin:removeDownload(catalog_id)
            if not path then
                self:_showInfo(_("This book could not be removed."))
                return
            end
            local BookList = require("ui/widget/booklist")
            BookList.resetBookInfoCache(path)
            local ReadHistory = require("readhistory")
            ReadHistory:fileDeleted(path)
            self:_afterLocalRemoval(entry)
            local Notification = require("ui/widget/notification")
            UIManager:show(Notification:new{ text = _("Removed from device") })
        end,
    })
end

-- Sideloaded books get KOReader's own permanent-delete flow (stock copy,
-- sidecar purge, history/collection cleanup). deleteFile's file branch is
-- instance-free, so the class table serves when no FileManager is open.
function LibraryUI:_confirmDeleteLocal(entry, file)
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance or FileManager
    fm:showDeleteFileDialog(file, function()
        self:_afterLocalRemoval(entry)
        local Notification = require("ui/widget/notification")
        UIManager:show(Notification:new{ text = _("Deleted from device") })
    end)
end

-- Shared post-removal bookkeeping. Deliberately does NOT purge the .sdr
-- sidecar on the Remove path: sidecars reattach by path and re-downloads
-- land at the same path, so reading progress survives remove/re-add.
function LibraryUI:_afterLocalRemoval(entry)
    entry.file = nil -- stale zone closures must not offer a gone file
    entry.path = nil
    self:_invalidateLibraryCache()
    UIManager:setDirty(self, "ui", self.dimen)
end

function LibraryUI:_addBooks()
    -- Open KOReader's stock OPDS catalog through the host's registered OPDS
    -- module (self.ui.opds; plugin name "opds"), the same handler its own menu
    -- item invokes. Guard on the handler's presence, not its type: at runtime
    -- onShowOPDSCatalog resolves to a callable value rather than a bare
    -- function, so a type=="function" check would wrongly fall through to the
    -- placeholder. If OPDS is absent, opds is nil and the placeholder is right.
    local opds = self.ui and self.ui.opds
    if not (opds and opds.onShowOPDSCatalog) then
        self:_showInfo(_("No book sources are configured."))
        return
    end

    opds:onShowOPDSCatalog()

    -- Refresh the library after the catalog closes. The OPDS browser stacks on
    -- top of this still-shown widget and pops via its close_callback; nothing
    -- on that path repaints the bookshelf or extracts a freshly downloaded
    -- file, so a kept-browsing download would otherwise not appear. The call
    -- above is synchronous and has already built opds.opds_browser with its
    -- close_callback, so we wrap that callback in place, fresh each time,
    -- against this live widget (no method monkeypatch, no stale capture).
    local browser = opds.opds_browser
    if browser then
        local previous_close = browser.close_callback
        local library = self
        browser.close_callback = function(...)
            if previous_close then
                previous_close(...)
            end
            if library._closed then
                return
            end
            library:_invalidateLibraryCache()
            library:_triggerBackgroundExtraction()
            UIManager:setDirty(library, "ui", library.dimen)
        end
    end
end

function LibraryUI:_zone(id, rect, callback, clip_rect)
    if clip_rect then
        if rect:notIntersectWith(clip_rect) then
            return
        end
        rect = rect:intersect(clip_rect)
        if rect.w <= 0 or rect.h <= 0 then
            return
        end
    end
    table.insert(self.zones, {
        id = id,
        rect = rect,
        callback = callback,
    })
end

function LibraryUI:_zoneAt(pos)
    if not pos then
        return nil
    end
    for i = #self.zones, 1, -1 do
        local zone = self.zones[i]
        if zone.rect:contains(pos) then
            return zone
        end
    end
end

function LibraryUI:_setPressedZone(zone)
    self.pressed_zone_id = zone.id
    UIManager:setDirty(self, "ui", zone.rect)
    UIManager:scheduleIn(0.05, function()
        if self._closed then
            return
        end
        self.pressed_zone_id = nil
        UIManager:setDirty(self, "ui", zone.rect)
        zone.callback()
    end)
end

function LibraryUI:_px(n)
    return GridLayout.scaleValue(n, self.shelf_scale or 1)
end

function LibraryUI:_iconSize()
    return self:_px(IconTokens.visual)
end

function LibraryUI:_iconTapSize()
    return self:_px(IconTokens.tap)
end

function LibraryUI:_layoutPx(token)
    return self:_px(assert(LayoutTokens[token], "unknown bookshelf layout token: " .. tostring(token)))
end

function LibraryUI:_hairline()
    return 1
end

function LibraryUI:_paintText(bb, text, x, y, options)
    options = options or {}
    local widget = TextWidget:new{
        text = text or "",
        face = Font:getFace(options.face or "smallinfofont", options.size or 22),
        bold = options.bold,
        fgcolor = options.color,
        max_width = options.max_width and clampWidth(options.max_width) or nil,
    }
    local size = widget:getSize()
    local paint_x = x
    local paint_y = y
    if options.align == "right" and options.width then
        paint_x = x + options.width - size.w
    elseif options.align == "center" and options.width then
        paint_x = x + math.floor((options.width - size.w) / 2)
    end
    if options.valign == "center" and options.height then
        paint_y = y + math.floor((options.height - size.h) / 2)
    end
    widget:paintTo(bb, paint_x, paint_y)
    widget:free()
    return size
end

function LibraryUI:_textSize(text, options)
    options = options or {}
    local widget = TextWidget:new{
        text = text or "",
        face = Font:getFace(options.face or "smallinfofont", options.size or 22),
        bold = options.bold,
        max_width = options.max_width and clampWidth(options.max_width) or nil,
    }
    local size = widget:getSize()
    widget:free()
    return size
end

function LibraryUI:_textBoxLineMetrics(face_name, size, line_height, lines, bold)
    local face = Font:getFace(face_name, size)
    face = Font:getAdjustedFace(face, bold)
    local line_h = Math.round((1 + line_height) * face.size)
    local face_h = face.ftsize:getHeightAndAscender()
    local line_heights_diff = math.floor(line_h - face_h)
    local glyph_extra_h = line_heights_diff < 0 and -line_heights_diff or 0
    local text_h = line_h * math.max(1, tonumber(lines) or 1)
    return {
        line_h = line_h,
        glyph_extra_h = glyph_extra_h,
        text_h = text_h,
        h = text_h + glyph_extra_h,
    }
end

function LibraryUI:_bookTextStack(kind)
    kind = kind or "small"
    self._book_text_stack = self._book_text_stack or {}
    if self._book_text_stack[kind] then
        return self._book_text_stack[kind]
    end

    local spec = assert(GridLayout.spec(kind), "unknown bookshelf grid kind: " .. tostring(kind))
    local title = self:_textBoxLineMetrics(
        FontTokens.sans_bold,
        spec.title_size,
        BookTextTokens.title_line_height,
        BookTextTokens.title_max_lines)
    local metadata = self:_textBoxLineMetrics(
        FontTokens.sans,
        spec.metadata_size,
        BookTextTokens.metadata_line_height,
        1)

    local stack = {
        title_h = title.h,
        title_line_h = title.line_h,
        title_text_h = title.text_h,
        title_glyph_extra_h = title.glyph_extra_h,
        title_line_height = BookTextTokens.title_line_height,
        title_max_lines = BookTextTokens.title_max_lines,
        metadata_h = metadata.h,
        metadata_line_h = metadata.line_h,
        metadata_text_h = metadata.text_h,
        metadata_glyph_extra_h = metadata.glyph_extra_h,
        metadata_line_height = BookTextTokens.metadata_line_height,
    }
    self._book_text_stack[kind] = stack
    return stack
end

function LibraryUI:_bookCardMetrics(kind, card_scale)
    return GridLayout.metrics(kind, card_scale or self.shelf_scale, self:_bookTextStack(kind))
end

function LibraryUI:_coverSpecs()
    local w = self.dimen and self.dimen.w or Screen:getWidth()
    local h = self.dimen and self.dimen.h or Screen:getHeight()
    local viewport_scale = self.shelf_scale or GridLayout.scaleForViewport(w, h)
    local large = self:_recentlyAddedRailMetrics(w)
    local small = self:_bookCardMetrics("small", viewport_scale)
    local continue = self:_continueCardMetrics(viewport_scale)
    return {
        max_cover_w = math.max(large.cover_w, small.cover_w, continue.cover_h * 2),
        max_cover_h = math.max(large.cover_h, small.cover_h, continue.cover_h),
    }
end

function LibraryUI:_paintTextBox(bb, text, x, y, width, options)
    options = options or {}
    local widget = TextBoxWidget:new{
        text = text or "",
        face = Font:getFace(options.face or "cfont", options.size or 22),
        bold = options.bold,
        fgcolor = options.color,
        width = clampWidth(width),
        height = options.height and clampWidth(options.height) or nil,
        height_adjust = options.height_adjust,
        height_overflow_show_ellipsis = options.height ~= nil,
        alignment = options.align or "left",
        line_height = options.line_height or 0.18,
    }
    local size = widget:getSize()
    widget:paintTo(bb, x, y)
    widget:free(true)
    return size
end

function LibraryUI:_paintLine(bb, x, y, w, color)
    bb:paintRect(x, y, w, self:_hairline(), color or Blitbuffer.COLOR_LIGHT_GRAY)
end

function LibraryUI:_paintRectBorder(bb, x, y, w, h, color)
    color = color or Blitbuffer.COLOR_LIGHT_GRAY
    local line = self:_hairline()
    self:_paintLine(bb, x, y, w, color)
    self:_paintLine(bb, x, y + h - line, w, color)
    bb:paintRect(x, y, line, h, color)
    bb:paintRect(x + w - line, y, line, h, color)
end

function LibraryUI:_paintPressedRect(bb, id, x, y, w, h)
    -- nil == nil must not count as "pressed": headers painted without an
    -- id (Discover rails) would otherwise show a permanent pressed band
    if id and self.pressed_zone_id == id then
        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY)
    end
end

function LibraryUI:_paintIcon(bb, icon, x, y, size, selected)
    Icons.paint(bb, icon, x, y, size, {
        selected = selected,
    })
end

function LibraryUI:_paintCenteredIcon(bb, icon, x, y, w, h, selected)
    local icon_size = self:_iconSize()
    local icon_x = x + math.floor((w - icon_size) / 2)
    local icon_y = y + math.floor((h - icon_size) / 2)
    self:_paintIcon(bb, icon, icon_x, icon_y, icon_size, selected)
    return icon_size
end

function LibraryUI:_paintStatusBar(bb, x, y, w)
    local time_text = os.date("%I:%M %p"):gsub("^0", "")
    self:_paintText(bb, time_text, x, y, {
        face = FontTokens.sans,
        size = 13,
        max_width = math.floor(w * 0.4),
    })

    local battery = nil
    if Device.powerd and type(Device.powerd.getCapacity) == "function" then
        local ok, capacity = pcall(Device.powerd.getCapacity, Device.powerd)
        if ok and capacity then
            battery = tonumber(capacity)
        end
    end
    if battery and battery > 0 then
        local battery_text = string.format("%d%%", battery)
        self:_paintText(bb, battery_text, x, y, {
            face = FontTokens.sans,
            size = 13,
            align = "right",
            width = w - self:_px(30),
            max_width = self:_px(64),
        })
        local icon_x = x + w - self:_px(26)
        local icon_y = y + self:_px(5)
        self:_paintRectBorder(bb, icon_x, icon_y, self:_px(20), self:_px(10), Blitbuffer.COLOR_DARK_GRAY)
        bb:paintRect(icon_x + self:_px(21), icon_y + self:_px(3), self:_px(2), self:_px(4), Blitbuffer.COLOR_DARK_GRAY)
    end
end

function LibraryUI:_paintHeaderAction(bb, id, icon, x, y, tap_size, callback)
    self:_paintPressedRect(bb, id, x, y, tap_size, tap_size)
    self:_paintCenteredIcon(bb, icon, x, y, tap_size, tap_size, false)
    self:_zone(id, Geom:new{x = x, y = y, w = tap_size, h = tap_size}, callback)
end

function LibraryUI:_paintHeader(bb, x, y, w)
    self:_paintText(bb, self.title, x, y, {
        face = FontTokens.display_italic,
        size = TypeScale.page_title,
        max_width = w - self:_px(164),
    })

    local action = self:_iconTapSize()
    local gap = self:_px(10)
    local right = x + w - action
    self:_paintHeaderAction(bb, "more", "more", right, y + self:_px(4), action, function()
        self:_showMore()
    end)
    right = right - action - gap
    self:_paintHeaderAction(bb, "filter", "filter", right, y + self:_px(4), action, function()
        self:_showFilter()
    end)
    right = right - action - gap
    self:_paintHeaderAction(bb, "search", "search", right, y + self:_px(4), action, function()
        self:_showLibrarySearch()
    end)
end

function LibraryUI:_categoryControlLayout(control, max_width)
    local gap = self:_px(4)
    local label_size = self:_textSize(control.label, {
        face = FontTokens.sans,
        size = TypeScale.category,
    })
    local value_size = self:_textSize(control.value, {
        face = FontTokens.sans_bold,
        size = TypeScale.category,
    })
    local natural_w = label_size.w + gap + value_size.w
    local width = math.min(natural_w, control.width or natural_w, max_width or natural_w)
    local label_w = label_size.w
    local value_w = value_size.w
    if natural_w > width then
        label_w = math.min(label_w, math.floor(width * 0.46))
        value_w = math.max(1, width - label_w - gap)
    end
    return {
        w = width,
        label_w = label_w,
        value_w = value_w,
        gap = gap,
    }
end

function LibraryUI:_paintCategoryControl(bb, control, x, y, layout)
    layout = layout or self:_categoryControlLayout(control)
    self:_paintText(bb, control.label, x, y, {
        face = FontTokens.sans,
        size = TypeScale.category,
        max_width = layout.label_w,
    })
    self:_paintText(bb, control.value, x + layout.label_w + layout.gap, y, {
        face = FontTokens.sans_bold,
        size = TypeScale.category,
        max_width = layout.value_w,
    })
end

function LibraryUI:_paintCategoryHeader(bb, opts)
    opts = opts or {}
    local x = opts.x
    local y = opts.y
    local w = opts.w
    local id = opts.id
    local callback = opts.callback

    self:_paintPressedRect(bb, id, x, y - self:_px(6), w, self:_px(34))
    local right = x + w
    local controls = opts.controls or {}
    local control_gap = self:_px(24)
    local control_layouts = {}
    for i = #controls, 1, -1 do
        local max_control_w = math.max(1, right - x)
        local layout = self:_categoryControlLayout(controls[i], max_control_w)
        layout.x = right - layout.w
        control_layouts[i] = layout
        right = layout.x - control_gap
    end

    local text_right = math.max(x + self:_px(32), right)
    local text_w = math.max(1, text_right - x)
    local title_size = self:_paintText(bb, opts.title, x, y, {
        face = FontTokens.sans_bold,
        size = TypeScale.category,
        max_width = opts.count_text and math.floor(text_w * 0.55) or text_w,
    })
    if opts.count_text and opts.count_text ~= "" then
        local count_x = x + title_size.w + self:_px(12)
        self:_paintText(bb, opts.count_text, count_x, y, {
            face = FontTokens.sans,
            size = TypeScale.category,
            color = Blitbuffer.COLOR_DARK_GRAY,
            max_width = math.max(1, text_right - count_x),
        })
    end

    for i, control in ipairs(controls) do
        self:_paintCategoryControl(bb, control, control_layouts[i].x, y, control_layouts[i])
    end

    if opts.chevron then
        local icon_size = self:_iconSize()
        self:_paintIcon(bb, "chevron_right", x + title_size.w + self:_px(6),
            y + math.floor((title_size.h - icon_size) / 2), icon_size, false)
    end
    if id and callback then
        self:_zone(id, Geom:new{x = x, y = y - self:_px(6), w = w, h = self:_px(34)}, callback)
    end
end

function LibraryUI:_paintSectionHeader(bb, text, count_text, action_text, x, y, w, id, callback)
    self:_paintCategoryHeader(bb, {
        title = text,
        count_text = count_text,
        controls = action_text and {{ label = "", value = action_text, width = math.floor(w * 0.42) }} or nil,
        chevron = not action_text,
        x = x,
        y = y,
        w = w,
        id = id,
        callback = callback,
    })
end

function LibraryUI:_coverTitleLines(title, max_lines)
    title = tostring(title or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if title == "" then
        return { _("Untitled") }
    end

    local words = {}
    for word in title:gmatch("%S+") do
        table.insert(words, word)
    end
    if #words <= 1 then
        return { title }
    end

    local target = math.max(8, math.ceil(#title / max_lines))
    local lines = {}
    local current = ""
    for _, word in ipairs(words) do
        if current ~= "" and #lines < max_lines and #current + 1 + #word > target then
            table.insert(lines, current)
            current = word
        elseif current == "" then
            current = word
        else
            current = current .. " " .. word
        end
    end
    if current ~= "" then
        table.insert(lines, current)
    end
    while #lines > max_lines do
        lines[max_lines] = lines[max_lines] .. " " .. table.remove(lines, max_lines + 1)
    end
    return lines
end

function LibraryUI:_entryHasCoverArtwork(entry)
    if type(entry) ~= "table" then
        return false
    end
    return entry.has_cover == true
        or entry.cover ~= nil
        or entry.cover_image ~= nil
        or entry.cover_path ~= nil
        or entry.thumbnail ~= nil
        or entry.thumbnail_path ~= nil
end

function LibraryUI:_bookInfoManager()
    if self._book_info_manager ~= nil then
        return self._book_info_manager or nil
    end

    local ok, manager = pcall(require, "bookinfomanager")
    if ok and type(manager) == "table" then
        self._book_info_manager = manager
        return manager
    end

    logger.warn("Bookshelf cover cache unavailable:", manager)
    self._book_info_manager = false
    return nil
end

function LibraryUI:_coverCacheKey(entry, w, h)
    local file = self:_entryFile(entry)
    if not file then
        return nil
    end
    return tostring(file) .. "|" .. tostring(w) .. "x" .. tostring(h)
end

function LibraryUI:_freeCoverCache()
    if type(self.cover_cache) ~= "table" then
        return
    end
    for _, cover in pairs(self.cover_cache) do
        if type(cover) == "table" and cover.bb and cover.bb.free then
            cover.bb:free()
        end
    end
    self.cover_cache = nil
end

function LibraryUI:_scheduleCoverCacheRetry()
    if self._cover_cache_retry_scheduled then
        return
    end
    if type(self.cover_cache) == "table" then
        for key, cover in pairs(self.cover_cache) do
            if cover == false then
                self.cover_cache[key] = nil
            end
        end
    end
    -- A stuck extraction must not repaint forever; covers that finish later
    -- still land on any natural repaint.
    self._cover_cache_retries = (self._cover_cache_retries or 0) + 1
    if self._cover_cache_retries > 10 then
        return
    end
    self._cover_cache_retry_scheduled = true
    UIManager:scheduleIn(1, function()
        self._cover_cache_retry_scheduled = false
        if not self._closed then
            UIManager:setDirty(self, "ui", self.dimen)
        end
    end)
end

function LibraryUI:_cachedCoverFor(entry, w, h)
    local key = self:_coverCacheKey(entry, w, h)
    if not key then
        return nil
    end
    self.cover_cache = self.cover_cache or {}
    local cached = self.cover_cache[key]
    if cached ~= nil then
        return cached or nil
    end

    local manager = self:_bookInfoManager()
    if not manager then
        return nil
    end

    local ok, bookinfo = pcall(manager.getBookInfo, manager, self:_entryFile(entry), true)
    if not ok or type(bookinfo) ~= "table" then
        self:_scheduleCoverCacheRetry()
        return nil
    end
    if tonumber(bookinfo.in_progress) and tonumber(bookinfo.in_progress) > 0 then
        self:_scheduleCoverCacheRetry()
        return nil
    end
    if not bookinfo.has_cover or not bookinfo.cover_bb then
        self.cover_cache[key] = false
        return nil
    end

    local cover_bb = bookinfo.cover_bb
    local source_w = cover_bb:getWidth()
    local source_h = cover_bb:getHeight()
    if not source_w or not source_h or source_w <= 0 or source_h <= 0 then
        if cover_bb.free then
            cover_bb:free()
        end
        self.cover_cache[key] = false
        return nil
    end

    local fit = math.min(w / source_w, h / source_h)
    local target_w = math.max(1, math.floor(source_w * fit))
    local target_h = math.max(1, math.floor(source_h * fit))
    if target_w ~= source_w or target_h ~= source_h then
        local RenderImage = require("ui/renderimage")
        cover_bb = RenderImage:scaleBlitBuffer(cover_bb, target_w, target_h, true)
    end

    cached = {
        bb = cover_bb,
        w = target_w,
        h = target_h,
    }
    self.cover_cache[key] = cached
    return cached
end

function LibraryUI:_coverFillColor(entry)
    if self:_entryHasCoverArtwork(entry) then
        return Blitbuffer.COLOR_WHITE
    elseif entry and entry.current then
        return Blitbuffer.COLOR_GRAY_D or Blitbuffer.COLOR_GRAY_E
    end
    return Blitbuffer.COLOR_GRAY_E
end

function LibraryUI:_paintBookCover(bb, entry, x, y, w, h, kind)
    self:_paintRectBorder(bb, x, y, w, h, Blitbuffer.COLOR_LIGHT_GRAY)
    local inset = self:_hairline()
    local fill = self:_coverFillColor(entry)
    bb:paintRect(x + inset, y + inset, w - inset * 2, h - inset * 2, fill)

    local cover = self:_cachedCoverFor(entry, w - inset * 2, h - inset * 2)
    if cover then
        bb:blitFrom(cover.bb,
            x + inset + math.floor((w - inset * 2 - cover.w) / 2),
            y + inset + math.floor((h - inset * 2 - cover.h) / 2),
            0, 0, cover.w, cover.h)
        return
    end

    local title = self:_entryTitle(entry) or _("Untitled")
    local lines = self:_coverTitleLines(title, 2)
    local compact = kind == "small"
    local font_size = compact and 11 or 14
    local line_step = self:_px(compact and 14 or 19)
    local title_block_h = #lines * line_step
    local title_y = y + math.floor((h - title_block_h) / 2) - self:_px(compact and 3 or 8)
    for i, line in ipairs(lines) do
        self:_paintText(bb, line, x + self:_px(8), title_y + (i - 1) * line_step, {
            face = FontTokens.sans_bold,
            size = font_size,
            align = "center",
            width = w - self:_px(16),
            max_width = w - self:_px(16),
        })
    end

    if compact then
        local motif_y = y + h - self:_px(24)
        self:_paintLine(bb, x + self:_px(16), motif_y, w - self:_px(32), Blitbuffer.COLOR_LIGHT_GRAY)
        self:_paintLine(bb, x + self:_px(24), motif_y + self:_px(7), w - self:_px(48), Blitbuffer.COLOR_LIGHT_GRAY)
    else
        local author = self:_entryAuthor(entry) or _("Document")
        self:_paintText(bb, author, x + self:_px(12), y + h - self:_px(34), {
            face = FontTokens.sans,
            size = TypeScale.card_meta,
            color = Blitbuffer.COLOR_DARK_GRAY,
            align = "center",
            width = w - self:_px(24),
            max_width = w - self:_px(24),
        })
        local rule_w = math.floor(w * 0.34)
        self:_paintLine(bb, x + math.floor((w - rule_w) / 2), y + self:_px(18), rule_w, Blitbuffer.COLOR_LIGHT_GRAY)
    end
end

function LibraryUI:_progressSummary(entry)
    if type(entry) ~= "table" then
        return ""
    end
    local percent = clampPercent(entry.percent_finished)
    local percent_text = string.format("%d%% read", math.floor(percent * 100 + 0.5))
    local page = tonumber(entry.current_page)
    local pages = tonumber(entry.pages)
    if not page and pages and pages > 1 and percent > 0 then
        page = math.min(pages, math.max(1, math.floor(percent * pages + 0.5)))
    end
    if page and pages and pages > 1 then
        return T(_("%1 • Page %2 of %3"), percent_text, page, pages)
    end
    return percent_text
end

function LibraryUI:_paintProgressLine(bb, x, y, w, percentage)
    local bar_h = math.max(1, self:_px(Space.xs))
    percentage = clampPercent(percentage)
    bb:paintRect(x, y, w, bar_h, Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(x, y, math.floor(w * percentage), bar_h, Blitbuffer.COLOR_BLACK)
end

function LibraryUI:_paintBookCard(bb, entry, slot, id, options)
    options = options or {}
    local kind = options.kind or "small"
    local metrics = self:_bookCardMetrics(kind, options.scale or slot.scale or self.shelf_scale)
    local title = self:_entryTitle(entry) or _("Untitled")
    local author = self:_entryAuthor(entry) or ""

    self:_paintPressedRect(bb, id, slot.x, slot.y, slot.w, slot.h)
    self:_paintBookCover(bb, entry, slot.cover.x, slot.cover.y, slot.cover.w, slot.cover.h, kind)
    self:_paintTextBox(bb, title, slot.title.x, slot.title.y, slot.title.w, {
        face = FontTokens.sans_bold,
        size = metrics.title_size,
        height = slot.title.h,
        height_adjust = true,
        line_height = metrics.title_line_height or BookTextTokens.title_line_height,
    })
    if author == "" and options.show_state then
        author = entry and entry.status == "reading" and _("Reading") or _("New")
    end
    self:_paintTextBox(bb, author, slot.metadata.x, slot.metadata.y, slot.metadata.w, {
        face = FontTokens.sans,
        size = metrics.metadata_size,
        color = Blitbuffer.COLOR_DARK_GRAY,
        height = slot.metadata.h,
        height_adjust = true,
        line_height = metrics.metadata_line_height or BookTextTokens.metadata_line_height,
    })

    self:_paintCenteredIcon(bb, "more", slot.menu.x, slot.menu.y, slot.menu.w, slot.menu.h, false)
    if entry then
        self:_zone(id, Geom:new{x = slot.x, y = slot.y, w = slot.w, h = slot.h}, function()
            self:_openEntry(entry)
        end, options.clip_rect)
        self:_zone(id .. "_menu", Geom:new{x = slot.menu.x - self:_px(8), y = slot.menu.y - self:_px(8),
            w = slot.menu.w + self:_px(16), h = slot.menu.h + self:_px(16)}, function()
            self:_showBookPanel(entry)
        end, options.clip_rect)
    end
end

function LibraryUI:_paintEmptyShelf(bb, x, y, w, centered)
    local title = centered and _("Your library is empty") or _("No books yet")
    local body = centered
        and _("Books, PDFs, and documents you add will appear here.")
        or _("Books you add will appear here.")
    self:_paintText(bb, title, x, y, {
        face = centered and FontTokens.display or FontTokens.sans_bold,
        size = centered and 28 or 14,
        align = centered and "center" or nil,
        width = centered and w or nil,
        max_width = w,
    })
    self:_paintTextBox(bb, body, x, y + self:_px(centered and 42 or 32), w, {
        face = FontTokens.sans,
        size = centered and 14 or 12,
        color = Blitbuffer.COLOR_DARK_GRAY,
        align = centered and "center" or "left",
        height = self:_px(centered and 52 or 36),
        line_height = 0.12,
    })
end

function LibraryUI:_paintEmptyHome(bb, x, y, w)
    self:_paintEmptyShelf(bb, x, y, w, true)
    local action_y = y + self:_px(124)
    local item_w = math.floor(w / 2)
    self:_paintText(bb, _("Add Books"), x, action_y, {
        face = FontTokens.sans_bold,
        size = 17,
        align = "center",
        width = item_w,
        max_width = item_w,
    })
    self:_paintText(bb, _("Dictionary"), x + item_w, action_y, {
        face = FontTokens.sans,
        size = 17,
        align = "center",
        width = item_w,
        max_width = item_w,
    })
    self:_zone("empty_add", Geom:new{x = x, y = action_y - self:_px(18), w = item_w, h = self:_px(56)}, function()
        self:_addBooks()
    end)
    self:_zone("empty_dictionary", Geom:new{x = x + item_w, y = action_y - self:_px(18), w = item_w, h = self:_px(56)}, function()
        self:_showDictionaryLookup()
    end)
end

function LibraryUI:_paintEmptyShelfPlaceholder(bb, x, y, w, h)
    local line = self:_hairline()
    local dash = self:_px(8)
    local gap = self:_px(6)
    local color = Blitbuffer.COLOR_LIGHT_GRAY
    for cursor = x, x + w - dash, dash + gap do
        bb:paintRect(cursor, y, math.min(dash, x + w - cursor), line, color)
        bb:paintRect(cursor, y + h - line, math.min(dash, x + w - cursor), line, color)
    end
    for cursor = y, y + h - dash, dash + gap do
        bb:paintRect(x, cursor, line, math.min(dash, y + h - cursor), color)
        bb:paintRect(x + w - line, cursor, line, math.min(dash, y + h - cursor), color)
    end
    self:_paintEmptyShelf(bb, x + self:_px(16), y + math.floor((h - self:_px(48)) / 2), w - self:_px(32), true)
end

function LibraryUI:_shelfPadding(kind)
    return self:_bookCardMetrics(kind or "large", self.shelf_scale).gutter
end

function LibraryUI:_continueShelfBodyHeight()
    if self:_continueEntry() then
        return self:_continueCardMetrics().h
    end
    return self:_bookCardMetrics("large", self.shelf_scale).card_h
end

function LibraryUI:_continueShelfMinBodyHeight()
    return self:_px(116)
end

function LibraryUI:_continueCardMetrics(card_scale)
    card_scale = card_scale or self.shelf_scale or 1
    local pad = self:_shelfPadding("large")
    local spec = GridLayout.spec("large")
    local h = GridLayout.scaleValue(spec.cover_w * GridLayout.cover_ratio, card_scale) + pad * 2
    return {
        pad = pad,
        -- The cover bleeds to the card's top, left, and bottom edges so it
        -- left-aligns with the shelf covers below and reads a size larger.
        cover_w = math.floor(h / GridLayout.cover_ratio + 0.5),
        cover_h = h,
        h = h,
    }
end

function LibraryUI:_paintContinueCard(bb, entry, x, y, w, h)
    local metrics = self:_continueCardMetrics()
    h = h or metrics.h
    local pad = metrics.pad
    local cover_h = math.max(1, h)

    self:_paintPressedRect(bb, "continue_card", x, y, w, h)
    self:_paintRectBorder(bb, x, y, w, h, Blitbuffer.COLOR_LIGHT_GRAY)

    -- The cover bleeds flush to the card's top, left, and bottom edges and
    -- keeps the artwork's own aspect, so the art never letterboxes; the 2:3
    -- placeholder box is only used when no artwork exists.
    local cover = self:_cachedCoverFor(entry, cover_h * 2, cover_h)
    local cover_w
    if cover then
        cover_w = cover.w
        bb:blitFrom(cover.bb, x, y + math.floor((h - cover.h) / 2), 0, 0, cover.w, cover.h)
        self:_paintRectBorder(bb, x, y, cover_w, cover_h, Blitbuffer.COLOR_LIGHT_GRAY)
    else
        cover_w = math.floor(cover_h / GridLayout.cover_ratio + 0.5)
        self:_paintBookCover(bb, entry, x, y, cover_w, cover_h, "large")
    end

    local menu_size = self:_iconSize()
    local text_x = x + cover_w + self:_px(Space.xl)
    local menu_x = x + w - pad - menu_size
    local text_w = math.max(1, menu_x - self:_px(Space.m) - text_x)
    local text_top = y + pad

    local title_metrics = self:_textBoxLineMetrics(
        FontTokens.serif_safe,
        TypeScale.hero_title,
        BookTextTokens.title_line_height,
        BookTextTokens.title_max_lines)
    local title_size = self:_paintTextBox(bb, self:_entryTitle(entry) or _("Untitled"), text_x, text_top, text_w, {
        face = FontTokens.serif_safe,
        size = TypeScale.hero_title,
        height = math.min(title_metrics.h, math.max(1, h - pad * 2)),
        height_adjust = true,
        line_height = BookTextTokens.title_line_height,
    })

    local cursor_y = text_top + title_size.h
    local author = self:_entryAuthor(entry)
    if author and author ~= "" then
        local author_size = self:_paintText(bb, author, text_x, cursor_y + self:_px(Space.s), {
            face = FontTokens.sans,
            size = TypeScale.category,
            color = Blitbuffer.COLOR_DARK_GRAY,
            max_width = text_w,
        })
        cursor_y = cursor_y + self:_px(Space.s) + author_size.h
    end

    -- A book with no reading state yet gets no progress block: "0% read"
    -- and an empty bar would misrepresent a never-opened book.
    local meta_top = y + h - pad
    local percent = tonumber(entry and entry.percent_finished) or 0
    local has_progress = percent > 0
        or (entry and (entry.current or entry.status == "reading" or entry.status == "complete"))
    if has_progress then
        local bar_y = y + h - pad - math.max(1, self:_px(Space.xs))
        meta_top = bar_y
        local summary = self:_progressSummary(entry)
        if summary ~= "" then
            local summary_size = self:_textSize(summary, {
                face = FontTokens.sans,
                size = TypeScale.card_title,
                max_width = text_w,
            })
            meta_top = bar_y - self:_px(Space.s) - summary_size.h
            self:_paintText(bb, summary, text_x, meta_top, {
                face = FontTokens.sans,
                size = TypeScale.card_title,
                color = Blitbuffer.COLOR_DARK_GRAY,
                max_width = text_w,
            })
        end
        self:_paintProgressLine(bb, text_x, bar_y, text_w, entry.percent_finished)
    end

    local snippet = entry and entry.resume_snippet
    if type(snippet) == "string" and snippet ~= "" then
        local snippet_y = cursor_y + self:_px(Space.m)
        local line_metrics = self:_textBoxLineMetrics(
            FontTokens.display_italic,
            TypeScale.category,
            BookTextTokens.title_line_height,
            1)
        -- the chapter the snippet quotes, as a quiet attribution line;
        -- reserve its height before sizing the snippet box
        local chapter = entry and entry.resume_chapter
        local has_chapter = type(chapter) == "string" and chapter ~= ""
        local attribution_h = has_chapter and self:_px(20) or 0
        local available = meta_top - self:_px(Space.m) - snippet_y - attribution_h
        local lines = math.min(3, math.floor(available / line_metrics.line_h))
        if lines >= 1 then
            self:_paintTextBox(bb, "“" .. snippet .. "”", text_x, snippet_y, text_w, {
                face = FontTokens.display_italic,
                size = TypeScale.category,
                color = Blitbuffer.COLOR_DARK_GRAY,
                height = lines * line_metrics.line_h,
                height_adjust = true,
                line_height = BookTextTokens.title_line_height,
            })
            if has_chapter then
                self:_paintText(bb, "— " .. chapter,
                    text_x, snippet_y + lines * line_metrics.line_h + self:_px(4), {
                        face = FontTokens.sans,
                        size = TypeScale.card_meta,
                        color = Blitbuffer.COLOR_DARK_GRAY,
                        max_width = text_w,
                    })
            end
        end
    end

    self:_paintCenteredIcon(bb, "more", menu_x, y + pad, menu_size, menu_size, false)
    self:_zone("continue_card", Geom:new{x = x, y = y, w = w, h = h}, function()
        self:_continue()
    end)
    self:_zone("continue_card_menu", Geom:new{x = menu_x - self:_px(Space.s), y = y + pad - self:_px(Space.s),
        w = menu_size + self:_px(Space.l), h = menu_size + self:_px(Space.l)}, function()
        self:_showBookPanel(entry)
    end)

    return h
end

function LibraryUI:_paintContinueEmptyState(bb, x, y, w, h)
    h = h or self:_continueShelfBodyHeight()
    self:_paintRectBorder(bb, x, y, w, h, Blitbuffer.COLOR_LIGHT_GRAY)

    local pad = self:_shelfPadding("large")
    local icon_size = self:_iconSize()
    local icon_x = x + math.floor((w - icon_size) / 2)
    local group_h = icon_size + self:_px(10) + self:_px(24) + self:_px(14)
    local inner_h = math.max(1, h - pad * 2)
    local icon_y = y + pad + math.floor((inner_h - group_h) / 2)
    self:_paintIcon(bb, "open_book", icon_x, icon_y, icon_size, false)

    self:_paintText(bb, _("Nothing in progress yet"), x + pad, icon_y + icon_size + self:_px(10), {
        face = FontTokens.serif_safe,
        size = 13,
        align = "center",
        width = w - pad * 2,
        max_width = w - pad * 2,
    })
    self:_paintText(bb, _("Start reading a book and it will appear here."), x + pad, icon_y + icon_size + self:_px(34), {
        face = FontTokens.sans,
        size = 9,
        color = Blitbuffer.COLOR_DARK_GRAY,
        align = "center",
        width = w - pad * 2,
        max_width = w - pad * 2,
    })

    return h
end

function LibraryUI:_paintGridCards(bb, kind, entries, x, y, w, rows, id_prefix, options)
    options = options or {}
    local card_scale = options.scale or self.shelf_scale
    local grid = GridLayout.grid(kind, {
        x = x,
        y = y,
        w = w,
        rows = rows,
        item_count = #entries,
        scale = card_scale,
        text_stack = self:_bookTextStack(kind),
    })
    for i, slot in ipairs(grid.slots) do
        self:_paintBookCard(bb, entries[i], slot, id_prefix .. tostring(i), {
            kind = kind,
            scale = card_scale,
            show_state = options.show_state,
        })
    end
    return grid
end

function LibraryUI:_paintRailCards(bb, kind, entries, x, y, w, id_prefix, options)
    options = options or {}
    local first_index = math.max(1, tonumber(options.first_index) or 1)
    local rail = GridLayout.rail(kind, {
        x = x,
        y = y,
        w = w,
        item_count = #entries,
        full_count = options.full_count,
        peek = options.peek,
        scale = self.shelf_scale,
        text_stack = self:_bookTextStack(kind),
    })
    for i, slot in ipairs(rail.slots) do
        self:_paintBookCard(bb, entries[i], slot, id_prefix .. tostring(first_index + i - 1), {
            kind = kind,
            scale = rail.scale,
            show_state = options.show_state,
            clip_rect = options.clip_rect,
        })
    end
    return rail
end

function LibraryUI:_railState(rail_id)
    self.rail_state = self.rail_state or {}
    local state = self.rail_state[rail_id]
    if not state then
        state = {
            page = rail_id == "all_books" and (self.library_page or 1) or 1,
        }
        self.rail_state[rail_id] = state
    end
    return state
end

function LibraryUI:_setRailPage(rail_id, page)
    local state = self:_railState(rail_id)
    state.page = math.max(1, tonumber(page) or 1)
    if rail_id == "all_books" then
        self.library_page = state.page
    end
    return state.page
end

function LibraryUI:_registerRail(rail_id, rect, window)
    self.rail_regions = self.rail_regions or {}
    table.insert(self.rail_regions, {
        id = rail_id,
        rect = rect,
        page = window.page,
        max_page = window.max_page,
        visible_count = window.visible_count,
        step_count = window.step_count,
    })
end

function LibraryUI:_railAt(pos)
    if not pos or not self.rail_regions then
        return nil
    end
    for i = #self.rail_regions, 1, -1 do
        local rail = self.rail_regions[i]
        if rail.rect:contains(pos) then
            return rail
        end
    end
end

function LibraryUI:_paintCarouselRail(bb, rail_id, kind, entries, x, y, w, id_prefix, options)
    options = options or {}
    local capacity = GridLayout.rail(kind, {
        x = x,
        y = y,
        w = w,
        item_count = 999,
        full_count = options.full_count,
        peek = options.peek,
        scale = self.shelf_scale,
        text_stack = self:_bookTextStack(kind),
    })
    local step_count = math.max(1, tonumber(options.step_count or options.full_count) or capacity.visible_count)
    local window = GridLayout.pageWindow(#entries, capacity.visible_count, self:_railState(rail_id).page, step_count)
    self:_setRailPage(rail_id, window.page)

    local rect = Geom:new{x = x, y = y, w = w, h = capacity.metrics.card_h}
    local rail = self:_paintRailCards(
        bb,
        kind,
        entriesWindow(entries, window.first, window.count),
        x,
        y,
        w,
        id_prefix,
        {
            full_count = options.full_count,
            peek = options.peek,
            show_state = options.show_state,
            first_index = window.first,
            clip_rect = rect,
        })
    rail.window = window
    self:_registerRail(rail_id, rect, window)
    return rail
end

function LibraryUI:_sectionHeaderHeight()
    return self:_layoutPx("category_header")
end

function LibraryUI:_sectionGap()
    return self:_layoutPx("shelf_body_gap")
end

function LibraryUI:_titleToShelfGap()
    return self:_layoutPx("title_to_shelves")
end

function LibraryUI:_continueToLowerGap()
    return self:_layoutPx("continue_to_lower_gap")
end

function LibraryUI:_lowerShelfGap()
    return self:_layoutPx("lower_shelf_gap")
end

function LibraryUI:_lowerBottomMargin()
    return self:_layoutPx("lower_bottom_margin")
end

function LibraryUI:_continueShelfNaturalHeight()
    return self:_sectionHeaderHeight() + self:_sectionGap() + self:_continueShelfBodyHeight()
end

function LibraryUI:_continueShelfMinHeight()
    return self:_sectionHeaderHeight() + self:_sectionGap() + self:_continueShelfMinBodyHeight()
end

function LibraryUI:_recentlyAddedRailMetrics(w)
    local rail_scale = GridLayout.railScale("large", w or (self.dimen and self.dimen.w), {
        full_count = RailTokens.recent_full_count,
        peek = RailTokens.peek,
    })
    return self:_bookCardMetrics("large", rail_scale)
end

function LibraryUI:_recentlyAddedShelfHeight(w)
    return self:_sectionHeaderHeight() + self:_sectionGap() + self:_recentlyAddedRailMetrics(w).card_h
end

function LibraryUI:_allBooksRailMetrics()
    return self:_bookCardMetrics("small", self.shelf_scale)
end

function LibraryUI:_allBooksShelfHeight(rows)
    rows = math.max(1, tonumber(rows) or 1)
    local metrics = self:_allBooksRailMetrics()
    return self:_sectionHeaderHeight() + self:_sectionGap()
        + metrics.card_h * rows
        + metrics.row_gap * (rows - 1)
end

function LibraryUI:_shelfStackLayout(content_y, nav_y)
    local continue_gap = self:_continueToLowerGap()
    local lower_gap = self:_lowerShelfGap()
    local bottom_margin = self:_lowerBottomMargin()
    local continue_natural_h = self:_continueShelfNaturalHeight()
    local continue_min_h = math.min(continue_natural_h, self:_continueShelfMinHeight())
    local recent_h = self:_recentlyAddedShelfHeight(self.dimen and self.dimen.w)
    local all_min_h = self:_allBooksShelfHeight(1)
    local available_continue_h = nav_y - bottom_margin - content_y
        - continue_gap - recent_h - lower_gap - all_min_h
    local continue_h = math.min(continue_natural_h, math.max(continue_min_h, available_continue_h))
    local recent_y = content_y + continue_h + continue_gap
    local all_y = recent_y + recent_h + lower_gap
    local all_h = math.max(all_min_h, nav_y - bottom_margin - all_y)

    return {
        continue_y = content_y,
        continue_h = continue_h,
        continue_gap = continue_gap,
        recent_y = recent_y,
        recent_h = recent_h,
        lower_gap = lower_gap,
        all_y = all_y,
        all_h = all_h,
        bottom_margin = bottom_margin,
        lower_stack_h = recent_h + lower_gap + all_h,
        continue_shrunk = continue_h < continue_natural_h,
    }
end

function LibraryUI:_paintContinueShelf(bb, x, y, w, h)
    local entry = self:_continueEntry()
    local metrics = self:_bookCardMetrics("large", self.shelf_scale)
    local header_x = x + metrics.outer
    local header_w = w - metrics.outer * 2
    self:_paintSectionHeader(bb, _("Continue reading"), nil, nil, header_x, y, header_w, "continue_header", function()
        self:_continue()
    end)

    local grid_y = y + self:_sectionHeaderHeight() + self:_sectionGap()
    local body_h = h and math.max(1, h - self:_sectionHeaderHeight() - self:_sectionGap())
        or self:_continueShelfBodyHeight()
    if not entry then
        local empty_h = self:_paintContinueEmptyState(bb, x + metrics.outer, grid_y, header_w, body_h)
        return self:_sectionHeaderHeight() + self:_sectionGap() + empty_h
    end

    local card_h = math.min(body_h, self:_continueCardMetrics().h)
    self:_paintContinueCard(bb, entry, x + metrics.outer, grid_y, header_w, card_h)
    return self:_sectionHeaderHeight() + self:_sectionGap() + card_h
end

function LibraryUI:_paintRecentlyAdded(bb, x, y, w)
    local entries = self:_recentlyAddedEntries()
    local metrics = self:_recentlyAddedRailMetrics(w)
    local header_x = x + metrics.outer
    local header_w = w - metrics.outer * 2
    self:_paintSectionHeader(bb, _("Recently added"), nil, nil, header_x, y, header_w, "recently_added", function()
        self:_addBooks()
    end)
    local grid_y = y + self:_sectionHeaderHeight() + self:_sectionGap()
    if #entries == 0 then
        self:_paintEmptyShelfPlaceholder(bb, x + metrics.outer, grid_y, metrics.card_w * 2 + metrics.gutter, metrics.card_h)
        return self:_sectionHeaderHeight() + self:_sectionGap() + metrics.card_h
    end

    local rail = self:_paintCarouselRail(bb, "recently_added", "large", entries, x, grid_y, w, "recent_", {
        full_count = RailTokens.recent_full_count,
        peek = RailTokens.peek,
        show_state = true,
    })
    return self:_sectionHeaderHeight() + self:_sectionGap() + rail.metrics.card_h
end

function LibraryUI:_paintAllBooks(bb, x, y, w, h)
    local entries = self:_allBooksEntries()
    local count = #entries
    local total = #self:_libraryEntries()
    -- a filtered shelf must never be invisible: the count says so
    local count_text = count == total
        and T(N_("%1 item", "%1 items", count), count)
        or T(_("%1 of %2"), count, total)
    local sort_label = select(2, self:_librarySortKey())
    local metrics = self:_allBooksRailMetrics()
    local header_x = x + metrics.outer
    local header_w = w - metrics.outer * 2
    self:_paintLine(bb, self.dimen.x, y - self:_px(Space.l), self.dimen.w, Blitbuffer.COLOR_LIGHT_GRAY)
    self:_paintCategoryHeader(bb, {
        title = _("All books"),
        count_text = count_text,
        controls = {
            {
                label = _("Sort:"),
                value = sort_label,
                width = self:_px(112),
            },
        },
        x = header_x,
        y = y,
        w = header_w,
        id = "all_books_header",
        callback = function()
            self:_showSortDialog()
        end,
    })

    local grid_y = y + self:_sectionHeaderHeight() + self:_sectionGap()
    if count == 0 then
        self:_paintEmptyShelfPlaceholder(bb, x + metrics.outer, grid_y, metrics.card_w * 2 + metrics.gutter, metrics.card_h)
        return
    end

    -- Same rail grammar as recently added: a half cover at the edge signals
    -- there are more books to swipe to. The full count emerges from the width.
    self:_paintCarouselRail(bb, "all_books", "small", entries, x, grid_y, w, "book_", {
        full_count = GridLayout.columns("small", w, self.shelf_scale, self:_bookTextStack("small")),
        peek = RailTokens.peek,
    })
end

-- The four tabs, shared by the home and the Discover surface; the active tab
-- comes from the widget's active_nav_tab field (home by default).
function LibraryUI:_navItems()
    return {
        { id = "nav_library", text = _("Library"), icon = "library", callback = function() self:_navHome() end },
        { id = "nav_dictionary", text = _("Dictionary"), icon = "dictionary", callback = function() self:_showDictionaryLookup() end },
        { id = "nav_discover", text = _("Discover"), icon = "discover", callback = function() self:_showDiscover() end },
        { id = "nav_files", text = _("Files"), icon = "files", callback = function() self:_showFiles() end },
    }
end

function LibraryUI:_navHome()
    -- the home is already the Library tab; Discover overrides this to close
end

function LibraryUI:_showDiscover()
    if self._discover_ui and not self._discover_ui._closed then
        return
    end
    self._discover_class = self._discover_class
        or dofile(plugin_dir .. "/discover.lua")(LibraryUI, plugin_dir)
    local library = self
    self._discover_ui = self._discover_class:new{
        ui = self.ui,
        plugin = self.plugin,
        closed_callback = function()
            library._discover_ui = nil
            if not library._closed then
                UIManager:setDirty(library, "ui", library.dimen)
            end
        end,
    }
    UIManager:show(self._discover_ui)
end

function LibraryUI:_paintBottomNav(bb, x, y, w, h)
    self:_paintLine(bb, x, y, w)
    local labels = self:_navItems()
    local active = self.active_nav_tab or "nav_library"
    for _, item in ipairs(labels) do
        item.selected = item.id == active
    end
    local nav = GridLayout.bottomTabs{
        x = x,
        y = y,
        w = w,
        count = #labels,
        scale = self.shelf_scale,
    }
    for i, item in ipairs(labels) do
        local slot = nav.slots[i]
        self:_paintPressedRect(bb, item.id, slot.tap.x, slot.tap.y, slot.tap.w, slot.tap.h)
        self:_paintIcon(bb, item.icon, slot.icon.x, slot.icon.y, slot.icon.w, item.selected)
        self:_paintText(bb, item.text, slot.label.x, slot.label.y, {
            face = item.selected and FontTokens.sans_bold or FontTokens.sans,
            size = 11,
            color = item.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            align = "center",
            width = slot.label.w,
            height = slot.label.h,
            valign = "center",
            max_width = slot.label.w - self:_px(4),
        })
        self:_zone(item.id, Geom:new{x = slot.tap.x, y = slot.tap.y, w = slot.tap.w, h = slot.tap.h}, item.callback)
    end
end

function LibraryUI:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    self.dimen.w = Screen:getWidth()
    self.dimen.h = Screen:getHeight()
    self.zones = {}
    self.rail_regions = {}

    local w = self.dimen.w
    local h = self.dimen.h
    self.shelf_scale = GridLayout.scaleForViewport(w, h)
    local margin = self:_bookCardMetrics("small", self.shelf_scale).outer
    local inner_w = w - 2 * margin
    local nav_h = GridLayout.bottomTabs{w = w, count = 4, scale = self.shelf_scale}.h
    local cursor_y = y + self:_layoutPx("page_top")
    local has_books = #self:_libraryEntries() > 0
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)

    self:_paintStatusBar(bb, x + margin, cursor_y, inner_w)
    cursor_y = cursor_y + self:_layoutPx("status_to_title")

    self:_paintHeader(bb, x + margin, cursor_y, inner_w)
    cursor_y = cursor_y + self:_layoutPx("title_block") + self:_titleToShelfGap()

    if not has_books then
        self:_paintEmptyHome(bb, x + margin, cursor_y + self:_layoutPx("empty_home_offset"), inner_w)
        self:_paintBottomNav(bb, x, h - nav_h, w, nav_h)
        return
    end

    local nav_y = h - nav_h
    local shelf_layout = self:_shelfStackLayout(cursor_y, nav_y)
    self:_paintContinueShelf(bb, x, shelf_layout.continue_y, w, shelf_layout.continue_h)
    self:_paintRecentlyAdded(bb, x, shelf_layout.recent_y, w)
    self:_paintAllBooks(bb, x, shelf_layout.all_y, w, shelf_layout.all_h)

    self:_paintBottomNav(bb, x, nav_y, w, nav_h)
end

function LibraryUI:onTap(arg, ges)
    local zone = self:_zoneAt(ges and ges.pos)
    if zone and zone.callback then
        self:_setPressedZone(zone)
        return true
    end
    return true
end

function LibraryUI:onSwipe(arg, ges)
    local direction = ges and BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction ~= "west" and direction ~= "east" then
        return false
    end

    local rail = self:_railAt(ges and ges.pos)
    if not rail or rail.max_page <= 1 then
        return false
    end

    local state = self:_railState(rail.id)
    local next_page = state.page
    if direction == "west" then
        next_page = math.min(state.page + 1, rail.max_page)
    elseif direction == "east" then
        next_page = math.max(state.page - 1, 1)
    end
    if next_page == state.page then
        return false
    end

    self:_setRailPage(rail.id, next_page)
    UIManager:setDirty(self, "ui", rail.rect)
    return true
end

return LibraryUI
