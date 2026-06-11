-- Discover: full-screen catalog surface in the bookshelf grammar.
-- Stacks above the library home; paints instantly from the persisted
-- snapshot, refreshes rails and fills cover thumbnails async. Factory form:
-- ui.lua passes its live LibraryUI class so the visual grammar (painters,
-- zones, rails, lifecycle) is inherited rather than duplicated.
return function(LibraryUI, plugin_dir)

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local GridLayout = dofile(plugin_dir .. "/gridlayout.lua")
local CatalogSearch = dofile(plugin_dir .. "/catalogsearch.lua")

local THUMB_CACHE_DIR = DataStorage:getDataDir() .. "/cache/bookshelf"

local DiscoverUI = LibraryUI:extend{
    title = _("Discover"),
    covers_fullscreen = true, -- repaints start here, never walk the home beneath
    active_nav_tab = "nav_discover",
    dithered = true,
}

function DiscoverUI:init()
    -- mirrors LibraryUI:init's input wiring minus the home-library
    -- extraction kick (provider/lastfile are home-only concerns)
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.rail_regions = {}
    self.rail_state = {}
    self.ges_events.Tap = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
    self.ges_events.Swipe = {
        GestureRange:new{ ges = "swipe", range = self.dimen },
    }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self.catalog_search = self.catalog_search or CatalogSearch.new()
    -- settings read only, no network: cheap at open
    self._server = self.catalog_search:available() and self.catalog_search:getServer() or nil
    self._thumb_queue = {}
    self._thumb_inflight = {}

    local snapshot = self.plugin and self.plugin:discoverSnapshot()
    self._snapshot_fetched_at = snapshot and snapshot.fetched_at
    self._stale = snapshot ~= nil
    self.rails = self:_railsFromSnapshot(snapshot)
    self:_scheduleRailRefresh()
end

function DiscoverUI:_railsFromSnapshot(snapshot)
    local rails = { new = {}, hot = {} }
    local stored = snapshot and snapshot.rails or {}
    for key, list in pairs(rails) do
        local rows = stored[key] and stored[key].rows or {}
        for _i, row in ipairs(rows) do
            table.insert(list, self:_discoverEntry(row))
        end
    end
    return rails
end

function DiscoverUI:_discoverEntry(row)
    local entry = {
        title = row.title,
        display_title = row.title,
        authors = row.author,
        text = row.text,
        epub_href = row.epub_href,
        mimetype = row.mimetype,
        thumb_href = row.thumb_href,
        catalog_id = row.catalog_id,
        thumbnail = row.thumb_href, -- _entryHasCoverArtwork -> white cover fill
    }
    entry.file = self.plugin and self.plugin:downloadedPath(row.catalog_id) or nil
    -- the panel is every card's tap target; _openEntry dispatches callbacks
    -- before files, so no card/open override is needed
    local discover = self
    entry.callback = function()
        discover:_showBookPanel(entry)
    end
    return entry
end

function DiscoverUI:paintTo(bb, x, y)
    -- the five invariants from LibraryUI:paintTo: mutate dimen IN PLACE
    -- (init's GestureRanges hold this exact Geom), rebuild zones, reset the
    -- per-paint memo, derive shelf_scale before any _px call, white ground.
    self.dimen.x = x
    self.dimen.y = y
    self.dimen.w = Screen:getWidth()
    self.dimen.h = Screen:getHeight()
    self.zones = {}
    self.rail_regions = {}
    self._paint_cache = {}
    local w = self.dimen.w
    local h = self.dimen.h
    self.shelf_scale = GridLayout.scaleForViewport(w, h)
    local margin = self:_bookCardMetrics("small", self.shelf_scale).outer
    local inner_w = w - 2 * margin
    local nav_h = GridLayout.bottomTabs{ w = w, count = 4, scale = self.shelf_scale }.h
    local cursor_y = y + self:_layoutPx("page_top")
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)

    self:_paintStatusBar(bb, x + margin, cursor_y, inner_w)
    cursor_y = cursor_y + self:_layoutPx("status_to_title")
    self:_paintDiscoverHeader(bb, x + margin, cursor_y, inner_w)
    cursor_y = cursor_y + self:_layoutPx("title_block") + self:_titleToShelfGap()

    cursor_y = self:_paintDiscoverRail(bb, "discover_new",
        _("New in your library"), self.rails.new, x, cursor_y, w, margin)
    self:_paintDiscoverRail(bb, "discover_hot",
        _("Popular at home"), self.rails.hot, x, cursor_y, w, margin)

    self:_paintBottomNav(bb, x, h - nav_h, w, nav_h)
    self:_drainThumbQueue() -- kick fills for thumbs this paint missed
end

function DiscoverUI:_paintDiscoverHeader(bb, x, y, w)
    self:_paintText(bb, self.title, x, y, {
        face = LibraryUI._font_tokens.display_italic,
        size = 38,
        max_width = w,
    })
    if self._stale and self._snapshot_fetched_at then
        -- offline is a mode, not an error: whisper the snapshot's age
        self:_paintText(bb, T(_("as of %1"), os.date("%b %d, %H:%M", self._snapshot_fetched_at)),
            x, y + self:_layoutPx("title_block") - self:_px(6), {
                face = LibraryUI._font_tokens.sans,
                size = 11,
                color = Blitbuffer.COLOR_DARK_GRAY,
                max_width = w,
            })
    end
end

function DiscoverUI:_paintDiscoverRail(bb, rail_id, label, entries, x, y, w, margin)
    self:_paintSectionHeader(bb, label, nil, nil, x + margin, y, w - 2 * margin)
    y = y + self:_sectionHeaderHeight() + self:_layoutPx("shelf_body_gap")
    local metrics = self:_bookCardMetrics("small", self.shelf_scale)
    if #entries == 0 then
        -- never consume a painter's return value; placeholder + fixed height
        self:_paintEmptyShelfPlaceholder(bb, x + margin, y,
            metrics.card_w * 2 + metrics.gutter, metrics.card_h)
        return y + metrics.card_h + self:_layoutPx("lower_shelf_gap")
    end
    local rail = self:_paintCarouselRail(bb, rail_id, "small", entries, x, y, w,
        rail_id .. "_", {
            full_count = GridLayout.columns("small", w, self.shelf_scale,
                self:_bookTextStack("small")),
            peek = 0.5,
        })
    return y + rail.metrics.card_h + self:_layoutPx("lower_shelf_gap")
end

-- nav: the painter is inherited; only the two tab behaviors flip
function DiscoverUI:_navHome()
    self:closeBookshelf()
end

function DiscoverUI:_showDiscover()
    -- already here
end

-- Cover cache: local files delegate to the home's BookInfoManager path;
-- remote entries serve from the thumbnail pipeline. Same {bb,w,h} /
-- false-sentinel shape, so the inherited _freeCoverCache frees both kinds.
function DiscoverUI:_coverCacheKey(entry, w, h)
    if entry and entry.file then
        return LibraryUI._coverCacheKey(self, entry, w, h)
    end
    if entry and entry.catalog_id then
        return "catalog:" .. entry.catalog_id .. "|" .. tostring(w) .. "x" .. tostring(h)
    end
end

function DiscoverUI:_cachedCoverFor(entry, w, h)
    if entry and entry.file then
        return LibraryUI._cachedCoverFor(self, entry, w, h)
    end
    local key = self:_coverCacheKey(entry, w, h)
    if not key then
        return nil
    end
    self.cover_cache = self.cover_cache or {}
    local cached = self.cover_cache[key]
    if cached ~= nil then
        return cached or nil -- false = confirmed no art this open
    end
    if entry.thumb_href then
        self:_queueThumb(entry, w, h) -- async fill; placeholder paints now
    else
        self.cover_cache[key] = false
    end
    return nil
end

-- on-device mark: decorate the inherited card painter
function DiscoverUI:_paintBookCard(bb, entry, slot, id, options)
    LibraryUI._paintBookCard(self, bb, entry, slot, id, options)
    if entry and entry.file then
        local size = self:_px(14)
        bb:paintRect(slot.cover.x + slot.cover.w - size - self:_px(6),
            slot.cover.y + self:_px(6), size, size, Blitbuffer.COLOR_BLACK)
    end
end

function DiscoverUI:_thumbCachePath(catalog_id)
    return THUMB_CACHE_DIR .. "/" .. catalog_id:gsub("[^%w]+", "_") .. ".img"
end

function DiscoverUI:_queueThumb(entry, w, h)
    local key = self:_coverCacheKey(entry, w, h)
    if not key or self._thumb_inflight[key] then
        return
    end
    self._thumb_inflight[key] = true
    table.insert(self._thumb_queue, {
        key = key,
        catalog_id = entry.catalog_id,
        href = entry.thumb_href,
        w = w,
        h = h,
    })
end

function DiscoverUI:_drainThumbQueue()
    if self._thumb_drain_scheduled or #self._thumb_queue == 0 then
        return
    end
    self._thumb_drain_scheduled = true
    UIManager:scheduleIn(0.1, function()
        self._thumb_drain_scheduled = false
        if self._closed then
            return -- widget gone: cache freed, stop
        end
        -- a few jobs per slot keeps taps responsive; one repaint per drain
        -- slot instead of one per thumbnail
        local filled = false
        for _i = 1, 3 do
            local job = table.remove(self._thumb_queue, 1)
            if not job then
                break
            end
            filled = self:_fillThumb(job) or filled
        end
        if filled then
            UIManager:setDirty(self, "ui", self.dimen)
        end
        self:_drainThumbQueue()
    end)
end

-- Returns true when it cached a new bb. Bytes come from the disk cache
-- first, then the network (auth + 3s/5s caps); decode at native size, then
-- aspect-fit scale (scaleBlitBuffer with true consumes the native bb; the
-- returned bb belongs to cover_cache and is freed only by _freeCoverCache).
function DiscoverUI:_fillThumb(job)
    local data
    local path = self:_thumbCachePath(job.catalog_id)
    local file = io.open(path, "rb")
    if file then
        data = file:read("*a")
        file:close()
    elseif self._server and not self._thumb_offline then
        data = self.catalog_search:fetchThumbnail(self._server, job.href)
        if data then
            lfs.mkdir(THUMB_CACHE_DIR) -- best-effort; exists is a no-op error
            local out = io.open(path, "wb")
            if out then
                out:write(data)
                out:close()
            end
        else
            -- a dead server must not be hammered once per thumbnail
            self._thumb_offline = true
        end
    end
    if self._closed then
        return false -- never touch a freed cache
    end

    local bb = data and RenderImage:renderImageData(data, #data)
    local cached = false -- false = negative cache for this open
    if bb then
        local source_w, source_h = bb:getWidth(), bb:getHeight()
        if source_w and source_h and source_w > 0 and source_h > 0 then
            local fit = math.min(job.w / source_w, job.h / source_h)
            local target_w = math.max(1, math.floor(source_w * fit))
            local target_h = math.max(1, math.floor(source_h * fit))
            if target_w ~= source_w or target_h ~= source_h then
                bb = RenderImage:scaleBlitBuffer(bb, target_w, target_h, true)
            end
            cached = { bb = bb, w = target_w, h = target_h }
        else
            bb:free()
        end
    end

    self.cover_cache = self.cover_cache or {}
    self.cover_cache[job.key] = cached
    self._thumb_inflight[job.key] = nil
    return cached ~= false
end

function DiscoverUI:_scheduleRailRefresh()
    UIManager:nextTick(function()
        if self._closed or not self._server then
            return
        end
        if not NetworkMgr:isConnected() then
            return -- offline mode: the snapshot stands
        end
        -- re-resolve in case the user edited OPDS settings since open
        self._server = self.catalog_search:getServer() or self._server
        local rails, err = self.catalog_search:discoverRails(self._server)
        if self._closed or not rails then
            if err then
                logger.dbg("Bookshelf discover refresh failed:", err)
            end
            return
        end
        local snapshot = {
            fetched_at = os.time(),
            server_url = self._server.url,
            rails = {},
        }
        local fresh = { new = {}, hot = {} }
        for key in pairs(fresh) do
            local section = rails[key]
            if section then
                local rows = self.catalog_search:rail(self._server, section.href)
                if rows then
                    snapshot.rails[key] = { title = section.title, rows = rows }
                    for _i, row in ipairs(rows) do
                        table.insert(fresh[key], self:_discoverEntry(row))
                    end
                end
            end
        end
        if self._closed then
            return
        end
        self.rails = fresh
        if self.plugin then
            self.plugin:saveDiscoverSnapshot(snapshot)
        end
        self._stale = false
        self._snapshot_fetched_at = snapshot.fetched_at
        -- the world changed: drop negative thumb sentinels and stale
        -- inflight markers so the new rails can re-queue their art
        self._thumb_offline = nil
        if type(self.cover_cache) == "table" then
            for key, value in pairs(self.cover_cache) do
                if value == false and key:sub(1, 8) == "catalog:" then
                    self.cover_cache[key] = nil
                end
            end
        end
        for key in pairs(self._thumb_inflight) do
            if self.cover_cache == nil or self.cover_cache[key] == nil then
                self._thumb_inflight[key] = nil
            end
        end
        self:_pruneThumbCache(snapshot)
        UIManager:setDirty(self, "ui", self.dimen)
    end)
end

-- bound the disk cache to the books the rails actually show
function DiscoverUI:_pruneThumbCache(snapshot)
    local keep = {}
    for _k, rail in pairs(snapshot.rails or {}) do
        for _i, row in ipairs(rail.rows or {}) do
            if row.catalog_id then
                keep[self:_thumbCachePath(row.catalog_id)] = true
            end
        end
    end
    if lfs.attributes(THUMB_CACHE_DIR, "mode") ~= "directory" then
        return
    end
    for name in lfs.dir(THUMB_CACHE_DIR) do
        if name ~= "." and name ~= ".." then
            local path = THUMB_CACHE_DIR .. "/" .. name
            if not keep[path] then
                os.remove(path)
            end
        end
    end
end

function DiscoverUI:_showBookPanel(entry)
    local ButtonDialog = require("ui/widget/buttondialog")
    local Font = require("ui/font")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local Size = require("ui/size")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")

    -- on-device detection: live download-map lookup (re-stats the file)
    local local_path = (self.plugin and self.plugin:downloadedPath(entry.catalog_id))
        or entry.file

    local dialog
    local buttons = {
        {{
            text = _("Read now"),
            callback = function()
                UIManager:close(dialog)
                if local_path then
                    self:_openEntry({ file = local_path })
                else
                    self:_downloadEntry(entry, function(path)
                        self:_openEntry({ file = path })
                    end)
                end
            end,
        }},
    }
    if not local_path then
        table.insert(buttons, {{
            text = _("Add to device"),
            callback = function()
                UIManager:close(dialog)
                self:_downloadEntry(entry)
            end,
        }})
    end

    dialog = ButtonDialog:new{
        width_factor = 0.8,
        buttons = buttons,
    }

    local avail_w = dialog:getAddedWidgetAvailableWidth()
    local box_w, box_h = Screen:scaleBySize(132), Screen:scaleBySize(184)
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

function DiscoverUI:_downloadEntry(entry, and_then)
    if not self._server then
        self:_showInfo(_("Your library server is not configured."))
        return
    end
    NetworkMgr:runWhenConnected(function()
        UIManager:show(InfoMessage:new{ text = _("Downloading..."), timeout = 1 })
        UIManager:scheduleIn(1, function()
            if self._closed then
                return
            end
            local path, err = self.catalog_search:download(self._server, entry)
            if path then
                if self.plugin then
                    self.plugin:recordDownload(entry.catalog_id, path)
                end
                entry.file = path -- the card's on-device mark flips
                if and_then then
                    and_then(path)
                else
                    UIManager:setDirty(self, "ui", self.dimen)
                end
            else
                self:_showInfo(T(_("Download failed: %1"), err))
            end
        end)
    end)
end

return DiscoverUI
end
