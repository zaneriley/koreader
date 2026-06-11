local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local PlaceholderProvider = {
    is_placeholder = true,
}

function PlaceholderProvider:getDownloaded()
    return {}
end

function PlaceholderProvider:getContinue()
    return nil
end

local Bookshelf = WidgetContainer:extend{
    name = "bookshelf",
    is_doc_only = false,
    provider = nil,
    settings_file = DataStorage:getSettingsDir() .. "/bookshelf.lua",
}

-- Plugin-owned persistence: the Discover feed snapshot and the download map
-- (catalog book id -> local file). One writer per host lifetime; loaded
-- lazily so startup cost stays zero. LuaSettings only writes on :flush().
function Bookshelf:loadSettings()
    if self.settings then
        return
    end
    self.settings = LuaSettings:open(self.settings_file)
    self.settings:saveSetting("schema", 1)
    -- live by-reference table: collaborators mutate it in place
    self.downloads = self.settings:readSetting("downloads", {})
    self:_pruneDownloads()
    if self.settings_dirty then
        -- once per host session, off the paint path: safe to flush eagerly
        self.settings:flush()
        self.settings_dirty = false
    end
end

function Bookshelf:_pruneDownloads()
    for id, path in pairs(self.downloads) do
        if lfs.attributes(path, "mode") ~= "file" then
            self.downloads[id] = nil
            self.settings_dirty = true
        end
    end
end

function Bookshelf:downloadedPath(catalog_id)
    if not catalog_id then
        return nil
    end
    self:loadSettings()
    local path = self.downloads[catalog_id]
    if path and lfs.attributes(path, "mode") == "file" then
        return path
    end
end

function Bookshelf:recordDownload(catalog_id, path)
    if not catalog_id or not path then
        return
    end
    self:loadSettings()
    self.downloads[catalog_id] = path
    -- eager: this map is the ground truth for "on device", and e-ink
    -- devices suspend or die without warning
    self.settings:flush()
    self.settings_dirty = false
end

-- Small persisted UI preferences (sort key, filters): read-through and
-- eager-flushed like the rest of the plugin settings.
function Bookshelf:uiPref(key)
    self:loadSettings()
    local prefs = self.settings:readSetting("ui_prefs")
    return prefs and prefs[key]
end

function Bookshelf:saveUiPref(key, value)
    self:loadSettings()
    local prefs = self.settings:readSetting("ui_prefs", {})
    prefs[key] = value
    self.settings:saveSetting("ui_prefs", prefs)
    self.settings:flush()
    self.settings_dirty = false
end

-- Reverse lookup for the panel's Remove/Delete split: is this local file
-- one the plugin downloaded from the catalog? Paths are compared raw and
-- realpath-normalized — a symlink mismatch must never reclassify a
-- library-linked book into the irreversible delete flow.
function Bookshelf:catalogIdForFile(file)
    if type(file) ~= "string" or file == "" then
        return nil
    end
    self:loadSettings()
    local real = ffiUtil.realpath(file) or file
    for id, path in pairs(self.downloads) do
        if path == file or (ffiUtil.realpath(path) or path) == real then
            return id
        end
    end
end

-- Removes the local copy of a catalog-linked book: deletes the file and
-- retires EVERY map key pointing at it (the legacy-id migration means one
-- path can be reachable under two keys). Deliberately leaves the .sdr
-- sidecar: progress reattaches if the book is re-added at the same path.
-- Returns the removed path, or nil.
function Bookshelf:removeDownload(catalog_id)
    if not catalog_id then
        return nil
    end
    self:loadSettings()
    local path = self.downloads[catalog_id]
    if not path then
        return nil
    end
    local ok = os.remove(path)
    if not ok and lfs.attributes(path, "mode") == "file" then
        return nil -- file exists but could not be removed
    end
    for id, p in pairs(self.downloads) do
        if p == path then
            self.downloads[id] = nil
        end
    end
    -- eager: this map is the ground truth for "on device", and e-ink
    -- devices suspend or die without warning
    self.settings:flush()
    self.settings_dirty = false
    return path
end

-- Lazy one-time migration: earlier builds keyed downloads by the
-- thumbnail's URL path when the book had artwork. Resolve by the current
-- key first, then the legacy one — re-recording a legacy hit under the
-- current key so the old entry retires.
function Bookshelf:resolveDownload(catalog_id, legacy_id)
    local path = self:downloadedPath(catalog_id)
    if path or not legacy_id or legacy_id == catalog_id then
        return path
    end
    path = self:downloadedPath(legacy_id)
    if path and catalog_id then
        self.downloads[legacy_id] = nil
        self:recordDownload(catalog_id, path)
    end
    return path
end

function Bookshelf:discoverSnapshot()
    self:loadSettings()
    return self.settings:readSetting("discover_snapshot")
end

function Bookshelf:saveDiscoverSnapshot(snapshot)
    self:loadSettings()
    -- replace the whole key, never mutate the old table: a refresh is a new
    -- world, replacement makes torn half-old/half-new states impossible
    self.settings:saveSetting("discover_snapshot", snapshot)
    self.settings:flush()
    self.settings_dirty = false
end

-- FlushSettings (suspend/SaveState/host close) is the deferred safety net
-- for prune-only dirt; distinct from onSaveSettings (document settings).
function Bookshelf:onFlushSettings()
    if self.settings and self.settings_dirty then
        self.settings:flush()
        self.settings_dirty = false
    end
end

function Bookshelf:onDispatcherRegisterActions()
    Dispatcher:registerAction("library_show", {
        category = "none",
        event = "ShowLibrary",
        title = _("Library"),
        general = true,
    })
end

function Bookshelf:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:_scheduleLibraryHome()
end

function Bookshelf:addToMainMenu(menu_items)
    menu_items.bookshelf = {
        text = _("Library"),
        sorting_hint = "main",
        callback = function()
            self:onShowLibrary()
        end,
    }
end

function Bookshelf:_readSetting(name)
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        return G_reader_settings:readSetting(name)
    end
end

function Bookshelf:_isLibraryHome()
    local home_view = self:_readSetting("home_view")
    if home_view ~= nil then
        return home_view == "library"
    end
    return self:_readSetting("start_with") == "library"
end

function Bookshelf:_isReaderHost()
    return self.ui and self.ui.document ~= nil
end

function Bookshelf:onReaderReady()
    if not self:_isReaderHost() then
        return
    end
    local preset_id = self:_readSetting("bookshelf_auto_apply_reading_preset")
    if type(preset_id) ~= "string" or preset_id == "" then
        return
    end
    UIManager:nextTick(function()
        self:_applyReadingPreset(preset_id)
    end)
end

function Bookshelf:_applyReadingPreset(preset_id)
    local ok, ReadingPreset = pcall(dofile, self.path .. "/readingpreset.lua")
    if not ok then
        logger.warn("Bookshelf reading preset loader failed:", ReadingPreset)
        return false
    end

    local doc_props = self.ui and self.ui.doc_props or {}
    local preset_ok, preset = pcall(ReadingPreset.getPreset, preset_id)
    if not preset_ok then
        logger.warn("Bookshelf reading preset unknown:", preset_id)
        return false
    end
    if not ReadingPreset.appliesToLanguage(preset, doc_props.language) then
        logger.info("Bookshelf reading preset skipped: book language",
            tostring(doc_props.language), "is outside the preset's scope")
        return false
    end

    local derived_ok, result = pcall(ReadingPreset.deriveProfile, {
        preset_id = preset_id,
    })
    if not derived_ok then
        logger.warn("Bookshelf reading preset derivation failed:", result)
        return false
    end
    if result.result == "fail" then
        logger.warn("Bookshelf reading preset did not meet readable measure:", result.failure_owner)
        return false
    end

    -- An auto-applied preset should not stack a toast per changed setting.
    -- Dispatcher:execute overrides the notify source itself, so the only
    -- surviving lever is the user-facing source mask, narrowed transiently;
    -- SOURCE_ALWAYS_SHOW notifications still pass.
    local saved_mask = G_reader_settings:readSetting("notification_sources_to_show_mask")
    G_reader_settings:saveSetting("notification_sources_to_show_mask", 0)
    local exec_ok, exec_err = pcall(Dispatcher.execute, Dispatcher, result.profile)
    if saved_mask ~= nil then
        G_reader_settings:saveSetting("notification_sources_to_show_mask", saved_mask)
    else
        G_reader_settings:delSetting("notification_sources_to_show_mask")
    end
    if not exec_ok then
        logger.warn("Bookshelf reading preset dispatch failed:", exec_err)
        return false
    end

    -- ui.doc_props whitelists display fields; the raw engine props with the
    -- publisher identifiers live in the book's saved doc_props setting.
    local raw_props = self.ui and self.ui.doc_settings
        and self.ui.doc_settings:readSetting("doc_props") or {}
    local repair_css = ReadingPreset.publisherRepairCss(raw_props)
    if repair_css then
        result.css_tweak = (result.css_tweak and (result.css_tweak .. "\n") or "") .. repair_css
        logger.info("Bookshelf applied publisher template repair (Project Gutenberg).")
    end

    if self.ui and self.ui.styletweak and result.css_tweak then
        self.ui.styletweak.tweaks_by_id["bookshelf_preset_tweak"] = {
            id = "bookshelf_preset_tweak",
            priority = 999,

            css = result.css_tweak,
        }
        self.ui.styletweak.doc_tweaks["bookshelf_preset_tweak"] = true
        self.ui.styletweak:updateCssText(true)
        logger.info("Bookshelf injected CSS style tweak to override publisher formatting.")
    end

    logger.info(
        "Bookshelf applied reading preset:",
        preset_id,
        "font:",
        result.profile.set_font,
        "estimated_cpl:",
        result.candidate and result.candidate.estimated_cpl
    )
    return true
end

function Bookshelf:_scheduleLibraryHome()
    if self._library_home_scheduled or self:_isReaderHost() or not self:_isLibraryHome() then
        return
    end
    if not self.ui or type(self.ui.registerPostInitCallback) ~= "function" then
        return
    end

    self._library_home_scheduled = true
    self.ui:registerPostInitCallback(function()
        UIManager:nextTick(function()
            self:onShowLibrary()
        end)
    end)
end

function Bookshelf:getProvider()
    if self.provider then
        return self.provider
    end

    local provider_path = self.path and (self.path .. "/provider.lua")
    if provider_path and lfs.attributes(provider_path, "mode") == "file" then
        local loader, load_err = loadfile(provider_path)
        if loader then
            local ok, provider = pcall(loader)
            if ok then
                if type(provider) == "function" then
                    local provider_ok, provider_instance = pcall(provider, {
                        ui = self.ui,
                        plugin = self,
                    })
                    if provider_ok then
                        provider = provider_instance
                    else
                        logger.warn("Bookshelf provider factory failed:", provider_instance)
                        provider = nil
                    end
                elseif type(provider) == "table" and type(provider.new) == "function" then
                    local provider_ok, provider_instance = pcall(provider.new, provider, {
                        ui = self.ui,
                        plugin = self,
                    })
                    if provider_ok then
                        provider = provider_instance
                    else
                        logger.warn("Bookshelf provider init failed:", provider_instance)
                        provider = nil
                    end
                end

                if type(provider) == "table" then
                    self.provider = provider
                    return self.provider
                end
            else
                logger.warn("Bookshelf provider failed:", provider)
            end
        else
            logger.warn("Bookshelf provider could not be loaded:", load_err)
        end
    end

    self.provider = PlaceholderProvider
    return self.provider
end

function Bookshelf:onShowLibrary()
    if self.ui and self.ui.return_to_previous_view and type(self.ui.onClose) == "function" then
        self.ui:onClose()
        return true
    end

    if self.bookshelf_ui and not self.bookshelf_ui._closed then
        return true
    end

    local BookshelfUI = dofile(self.path .. "/ui.lua")

    self.bookshelf_ui = BookshelfUI:new{
        ui = self.ui,
        plugin = self,
        provider = self:getProvider(),
        closed_callback = function()
            self.bookshelf_ui = nil
        end,
    }
    UIManager:show(self.bookshelf_ui)
    return true
end

function Bookshelf:onShowHome()
    if self:_isLibraryHome() then
        return self:onShowLibrary()
    end
    return false
end

function Bookshelf:_captureResumeSnippet()
    if not (self.ui and self.ui.document) then
        return
    end
    -- SaveSettings and CloseDocument can both fire around one close;
    -- capture at most once per moment.
    local now = os.time()
    if self._snippet_captured_at and now - self._snippet_captured_at < 2 then
        return
    end
    local ok, ResumeSnippet = pcall(dofile, self.path .. "/resumesnippet.lua")
    if not ok then
        logger.warn("Bookshelf resume snippet loader failed:", ResumeSnippet)
        return
    end
    local capture_ok, captured = pcall(ResumeSnippet.capture, self.ui)
    if not capture_ok then
        logger.warn("Bookshelf resume snippet capture failed:", captured)
    elseif captured then
        self._snippet_captured_at = now
    end
end

-- The reader closes the document before its deferred settings flush, so
-- capture on CloseDocument (document still live); SaveSettings covers
-- suspend and periodic autosave while reading.
function Bookshelf:onSaveSettings()
    self:_captureResumeSnippet()
end

function Bookshelf:onCloseDocument()
    self:_captureResumeSnippet()
end

return Bookshelf
