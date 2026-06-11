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
local url = require("socket.url")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local GridLayout = dofile(plugin_dir .. "/gridlayout.lua")
local CatalogSearch = dofile(plugin_dir .. "/catalogsearch.lua")

local THUMB_CACHE_DIR = DataStorage:getDataDir() .. "/cache/bookshelf"

-- Vertical rail-stack paging (display units, scaled through _px)
local RailStackTokens = {
    indicator_band = 24, -- height reserved above the nav for the pager
    indicator_dot = 6, -- square side, echoing the on-device mark
    indicator_gap = 10,
}

-- Positive delay between refresh steps. Load-bearing: UIManager's input
-- loop drains every already-due task before polling input, so a zero
-- delay (nextTick) would run the whole fetch chain back-to-back with
-- taps and repaints starved until it ends. A real delay puts one fetch
-- per loop pass, with paint + input between. (Same shape as the thumb
-- drain below.)
local REFRESH_STEP_DELAY = 0.1

-- Bounds for what a refresh persists: the settings file is rewritten on
-- every successful refresh and the chain costs one fetch per rail, so
-- both scale with the server's shelf count unless capped.
local SnapshotLimits = {
    max_shelf_rails = 12,
    max_rows_per_rail = 24, -- ~3 carousel pages per rail
}

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

-- The two anchor rails keep their canonical surface labels; custom shelf
-- rails carry the reader's own shelf name from the catalog.
function DiscoverUI:_railLabel(rail)
    if rail.key == "new" then
        return _("New in your library")
    elseif rail.key == "hot" then
        return _("Popular at home")
    end
    return rail.title or ""
end

-- Snapshot rails are an ordered array of { key, title, rows }. The
-- snapshot is cache, not user data: anything else on disk (including the
-- pre-shelf { new, hot } map shape) is a cache miss that paints the
-- anchor skeleton until a refresh lands.
function DiscoverUI:_railsFromSnapshot(snapshot)
    local stored = snapshot and snapshot.rails or {}
    if #stored == 0 then
        stored = { { key = "new" }, { key = "hot" } }
    end
    local rails = {}
    for _i, rail in ipairs(stored) do
        local entries = {}
        for _j, row in ipairs(rail.rows or {}) do
            table.insert(entries, self:_discoverEntry(row))
        end
        table.insert(rails, {
            key = rail.key,
            label = self:_railLabel(rail),
            entries = entries,
        })
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
    -- legacy key: pre-identity-fix builds keyed downloads by the thumb path
    local legacy_id = row.thumb_href and (url.parse(row.thumb_href) or {}).path or nil
    entry.file = self.plugin and self.plugin:resolveDownload(row.catalog_id, legacy_id) or nil
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

    -- The rail stack pages vertically: as many full rails as fit between
    -- the header and the nav, swipe north/south for the rest. Same paging
    -- math as the horizontal carousels (GridLayout.pageWindow), with the
    -- whole page as the step.
    local rails = self.rails or {}
    local nav_y = y + h - nav_h
    local rail_pitch = self:_railPitch(w)
    local indicator_h = self:_px(RailStackTokens.indicator_band)
    local avail = nav_y - cursor_y - indicator_h
    -- a viewport too short for one rail still paints that rail, but the
    -- pager would overlap it: skip the squares, swipes still page
    local indicator_fits = avail >= rail_pitch
    local stack_h = math.max(rail_pitch, avail)
    local per_page = math.max(1, math.floor(stack_h / rail_pitch))
    local window = GridLayout.pageWindow(#rails, per_page, self._rail_stack_page, per_page)
    self._rail_stack_page = window.page
    self._rail_stack_pages = window.max_page
    for i = window.first, window.last do
        local rail = rails[i]
        cursor_y = self:_paintDiscoverRail(bb, "discover_" .. rail.key,
            rail.label, rail.entries, x, cursor_y, w, margin)
    end
    if indicator_fits then
        self:_paintRailStackIndicator(bb, x, w, nav_y - indicator_h, window.page, window.max_page)
    end

    self:_paintBottomNav(bb, x, nav_y, w, nav_h)
    self:_drainThumbQueue() -- kick fills for thumbs this paint missed
end

-- Quiet square pager above the nav: filled square = current page. Squares
-- echo the on-device mark; only painted when there is more than one page.
function DiscoverUI:_paintRailStackIndicator(bb, x, w, y, page, pages)
    if pages <= 1 then
        return
    end
    local size = self:_px(RailStackTokens.indicator_dot)
    local gap = self:_px(RailStackTokens.indicator_gap)
    local cursor = x + math.floor((w - (pages * size + (pages - 1) * gap)) / 2)
    for i = 1, pages do
        bb:paintRect(cursor, y, size, size,
            i == page and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY)
        cursor = cursor + size + gap
    end
end

-- Vertical swipes page the rail stack; horizontal swipes keep paging the
-- rail carousels through the inherited handler.
function DiscoverUI:onSwipe(arg, ges)
    local direction = ges and ges.direction
    if direction == "north" or direction == "south" then
        local pages = self._rail_stack_pages or 1
        local page = self._rail_stack_page or 1
        local next_page
        if direction == "north" then
            next_page = math.min(page + 1, pages)
        else
            next_page = math.max(page - 1, 1)
        end
        if next_page ~= page then
            self._rail_stack_page = next_page
            UIManager:setDirty(self, "ui", self.dimen)
        end
        return true
    end
    return LibraryUI.onSwipe(self, arg, ges)
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

-- One source for the discover rail geometry: full columns plus the
-- half-cover peek, exactly as the carousel painter will scale its cards.
-- The stack-paging pitch derives from the same numbers, so the page math
-- always matches what actually paints.
function DiscoverUI:_discoverRailOptions(w)
    return {
        full_count = GridLayout.columns("small", w, self.shelf_scale,
            self:_bookTextStack("small")),
        peek = 0.5,
    }
end

function DiscoverUI:_discoverRailMetrics(w)
    local rail_scale = GridLayout.railScale("small", w, self:_discoverRailOptions(w))
    return self:_bookCardMetrics("small", rail_scale)
end

-- Height one rail consumes in the stack: header, gap, card, trailing gap.
function DiscoverUI:_railPitch(w)
    return self:_sectionHeaderHeight() + self:_layoutPx("shelf_body_gap")
        + self:_discoverRailMetrics(w).card_h + self:_layoutPx("lower_shelf_gap")
end

function DiscoverUI:_paintDiscoverRail(bb, rail_id, label, entries, x, y, w, margin)
    self:_paintSectionHeader(bb, label, nil, nil, x + margin, y, w - 2 * margin)
    y = y + self:_sectionHeaderHeight() + self:_layoutPx("shelf_body_gap")
    local metrics = self:_discoverRailMetrics(w)
    if #entries == 0 then
        -- never consume a painter's return value; placeholder + fixed
        -- height, sized like the carousel so the stack pitch stays uniform
        self:_paintEmptyShelfPlaceholder(bb, x + margin, y,
            metrics.card_w * 2 + metrics.gutter, metrics.card_h)
        return y + metrics.card_h + self:_layoutPx("lower_shelf_gap")
    end
    local rail = self:_paintCarouselRail(bb, rail_id, "small", entries, x, y, w,
        rail_id .. "_", self:_discoverRailOptions(w))
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
    if self._refreshing then
        return
    end
    self._refreshing = true
    self:_scheduleNextRefreshStep({ phase = "plan" })
end

function DiscoverUI:_scheduleNextRefreshStep(state)
    UIManager:scheduleIn(REFRESH_STEP_DELAY, function()
        self:_refreshStep(state)
    end)
end

-- One network fetch per scheduled step, so each loop pass stays bounded
-- by a single time-capped request: plan (root feed) -> shelves (shelf
-- index) -> one step per rail feed.
function DiscoverUI:_refreshStep(state)
    if self._closed then
        self._refreshing = false
        return
    end
    if state.phase == "plan" then
        if not self._server or not NetworkMgr:isConnected() then
            self._refreshing = false
            return -- offline mode: the snapshot stands
        end
        -- re-resolve in case the user edited OPDS settings since open
        self._server = self.catalog_search:getServer() or self._server
        local sections, err = self.catalog_search:sections(self._server)
        local plan = sections and self.catalog_search:railPlan(sections)
        if not plan then
            logger.dbg("Bookshelf discover refresh failed:", err or "no rail plan")
            self._refreshing = false
            return
        end
        state.plan = plan.rails
        state.shelf_index = plan.shelf_index
        state.standing = self:_standingRows()
        state.snapshot = {
            fetched_at = os.time(),
            server_url = self._server.url,
            rails = {},
        }
        state.index = 0
        state.phase = state.shelf_index and "shelves" or "rails"
    elseif state.phase == "shelves" then
        local shelves = self.catalog_search:shelves(self._server, state.shelf_index)
        for _i = 1, math.min(#shelves, SnapshotLimits.max_shelf_rails) do
            table.insert(state.plan, shelves[_i])
        end
        if #shelves > SnapshotLimits.max_shelf_rails then
            logger.dbg("Bookshelf discover: dropped",
                #shelves - SnapshotLimits.max_shelf_rails, "shelf rails beyond the cap")
        end
        state.phase = "rails"
    else
        state.index = state.index + 1
        local rail = state.plan[state.index]
        if not rail then
            self:_finishRailRefresh(state.snapshot)
            return
        end
        local rows = self:_resolveRailRows(rail,
            self.catalog_search:rail(self._server, rail.href), state.standing)
        if rows then
            table.insert(state.snapshot.rails, { key = rail.key, title = rail.title, rows = rows })
        end
    end
    self:_scheduleNextRefreshStep(state)
end

-- What a rail contributes to the fresh snapshot: its fetched rows; the
-- standing snapshot's rows when the fetch FAILED (a transient timeout
-- must never erase cached rails or their disk thumbnails); an empty
-- anchor as the surface skeleton; nil to drop the rail. A successful
-- empty fetch ({}) on a shelf is a real "shelf emptied" and drops it.
function DiscoverUI:_resolveRailRows(rail, rows, standing)
    local anchor = rail.key == "new" or rail.key == "hot"
    if not rows then
        rows = standing[rail.key]
        if not rows and anchor then
            rows = {}
        end
    end
    if not rows or (#rows == 0 and not anchor) then
        return nil
    end
    if #rows > SnapshotLimits.max_rows_per_rail then
        local capped = {}
        for _i = 1, SnapshotLimits.max_rows_per_rail do
            capped[_i] = rows[_i]
        end
        return capped
    end
    return rows
end

-- The persisted snapshot's rows indexed by rail key, for carry-forward.
-- A pre-shelf map snapshot has no array part and yields nothing: cache miss.
function DiscoverUI:_standingRows()
    local standing = {}
    local snapshot = self.plugin and self.plugin:discoverSnapshot()
    for _i, rail in ipairs(snapshot and snapshot.rails or {}) do
        if rail.key then
            standing[rail.key] = rail.rows
        end
    end
    return standing
end

function DiscoverUI:_finishRailRefresh(snapshot)
    self._refreshing = false
    if self._closed then
        return
    end
    if #snapshot.rails == 0 then
        -- every fetch failed mid-chain: keep the standing snapshot
        logger.dbg("Bookshelf discover refresh produced no rails")
        return
    end
    self.rails = self:_railsFromSnapshot(snapshot)
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

-- The book panel itself is inherited from LibraryUI (_showBookPanel); this
-- surface only contributes _downloadEntry, which the shared panel calls
-- for entries that are not on the device.
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
