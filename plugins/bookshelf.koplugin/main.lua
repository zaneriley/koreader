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

return Bookshelf
