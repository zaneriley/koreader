local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
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
}

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
    return (self:_readSetting("start_with") or "library") == "library"
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
    local ok, ResumeSnippet = pcall(dofile, self.path .. "/resumesnippet.lua")
    if not ok then
        logger.warn("Bookshelf resume snippet loader failed:", ResumeSnippet)
        return
    end
    local capture_ok, capture_err = pcall(ResumeSnippet.capture, self.ui)
    if not capture_ok then
        logger.warn("Bookshelf resume snippet capture failed:", capture_err)
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
