describe("Bookshelf discover", function()
    local LibraryUI, DiscoverUI, Bookshelf

    setup(function()
        require("commonrequire")
        package.path = "plugins/opds.koplugin/?.lua;" .. package.path
        LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        DiscoverUI = dofile("plugins/bookshelf.koplugin/discover.lua")(
            LibraryUI, "plugins/bookshelf.koplugin")
        Bookshelf = dofile("plugins/bookshelf.koplugin/main.lua")
    end)

    local SNAPSHOT = {
        fetched_at = 1760000000,
        server_url = "http://lib.example/opds",
        rails = {
            { key = "new", title = "Recently added Books", rows = {
                {
                    title = "Difficult Conversations",
                    author = "Sheila Heen",
                    text = "Difficult Conversations - Sheila Heen",
                    epub_href = "http://lib.example/opds/download/306/epub/",
                    thumb_href = "http://lib.example/opds/cover/306",
                    catalog_id = "/opds/download/306/epub/",
                },
            } },
            { key = "hot", title = "Hot Books", rows = {} },
            { key = "shelf:/opds/shelf/8", title = "Learning Japanese", rows = {
                {
                    title = "それから",
                    author = "夏目 漱石",
                    text = "それから",
                    epub_href = "http://lib.example/opds/download/401/epub/",
                    catalog_id = "/opds/cover/401",
                },
            } },
        },
    }

    it("builds ordered rails from a snapshot with on-device resolution", function()
        local fake = setmetatable({
            plugin = {
                resolveDownload = function(_, catalog_id, legacy_id)
                    if catalog_id == "/opds/download/306/epub/" then
                        -- the thumb path rides along as the legacy lookup key
                        assert.equals("/opds/cover/306", legacy_id)
                        return "/downloads/difficult.epub"
                    end
                end,
            },
        }, { __index = DiscoverUI })

        local rails = DiscoverUI._railsFromSnapshot(fake, SNAPSHOT)

        assert.equals(3, #rails)
        -- anchors carry the surface's canonical labels, not server titles
        assert.equals("New in your library", rails[1].label)
        assert.equals("Popular at home", rails[2].label)
        -- a custom shelf rail carries the reader's own shelf name
        assert.equals("Learning Japanese", rails[3].label)
        assert.equals(1, #rails[3].entries)

        assert.equals(1, #rails[1].entries)
        assert.equals(0, #rails[2].entries)
        local entry = rails[1].entries[1]
        assert.equals("Difficult Conversations", entry.display_title)
        assert.equals("Sheila Heen", entry.authors)
        assert.equals("/downloads/difficult.epub", entry.file) -- on-device mark
        assert.is_function(entry.callback) -- card tap opens the panel
    end)

    it("treats a pre-shelf map snapshot as a cache miss", function()
        local fake = setmetatable({}, { __index = DiscoverUI })
        local rails = DiscoverUI._railsFromSnapshot(fake, {
            rails = {
                new = { title = "Recently added Books", rows = {
                    { title = "A", catalog_id = "/opds/cover/1" },
                } },
                hot = { title = "Hot Books", rows = {} },
            },
        })
        -- the snapshot is cache: an old shape paints the skeleton, not data
        assert.equals(2, #rails)
        assert.equals("New in your library", rails[1].label)
        assert.equals(0, #rails[1].entries)
    end)

    it("resolves rail rows with carry-forward on failed fetches", function()
        local fake = setmetatable({}, { __index = DiscoverUI })
        local standing = {
            ["shelf:/opds/shelf/8"] = { { title = "kept" } },
            new = { { title = "old new" } },
        }

        -- fetch failed (nil): the standing snapshot's rows survive
        local carried = DiscoverUI._resolveRailRows(fake,
            { key = "shelf:/opds/shelf/8" }, nil, standing)
        assert.equals("kept", carried[1].title)
        assert.equals("old new",
            DiscoverUI._resolveRailRows(fake, { key = "new" }, nil, standing)[1].title)

        -- failed anchor with nothing standing keeps its skeleton
        assert.same({}, DiscoverUI._resolveRailRows(fake, { key = "hot" }, nil, standing))
        -- failed shelf with nothing standing is dropped
        assert.is_nil(DiscoverUI._resolveRailRows(fake,
            { key = "shelf:/opds/shelf/9" }, nil, standing))
        -- a successful empty fetch is a real "shelf emptied" and drops it
        assert.is_nil(DiscoverUI._resolveRailRows(fake,
            { key = "shelf:/opds/shelf/8" }, {}, standing))

        -- persisted rows are capped
        local many = {}
        for i = 1, 40 do
            many[i] = { title = "b" .. i }
        end
        assert.equals(24, #DiscoverUI._resolveRailRows(fake, { key = "new" }, many, standing))
    end)

    it("seeds the anchor skeleton when no snapshot exists", function()
        local fake = setmetatable({}, { __index = DiscoverUI })
        local rails = DiscoverUI._railsFromSnapshot(fake, nil)
        assert.equals(2, #rails)
        assert.equals("New in your library", rails[1].label)
        assert.equals("Popular at home", rails[2].label)
        assert.equals(0, #rails[1].entries)
    end)

    it("pages the rail stack with vertical swipes and clamps at the edges", function()
        local UIManager = require("ui/uimanager")
        local dirty = 0
        local old_set_dirty = UIManager.setDirty
        finally(function()
            UIManager.setDirty = old_set_dirty
        end)
        UIManager.setDirty = function()
            dirty = dirty + 1
        end

        local fake = setmetatable({
            _rail_stack_page = 1,
            _rail_stack_pages = 3,
            rail_regions = {},
            dimen = {},
        }, { __index = DiscoverUI })

        assert.is_true(DiscoverUI.onSwipe(fake, nil, { direction = "north" }))
        assert.equals(2, fake._rail_stack_page)
        assert.is_true(DiscoverUI.onSwipe(fake, nil, { direction = "south" }))
        assert.equals(1, fake._rail_stack_page)
        local repaints = dirty
        assert.equals(2, repaints)
        -- clamped at the first page: consumed, no repaint
        assert.is_true(DiscoverUI.onSwipe(fake, nil, { direction = "south" }))
        assert.equals(1, fake._rail_stack_page)
        assert.equals(repaints, dirty)
        -- horizontal swipes still fall through to the carousel handler
        assert.is_false(DiscoverUI.onSwipe(fake, nil, { direction = "west", pos = nil }))
    end)

    it("paints one indicator square per rail page, none for a single page", function()
        local Blitbuffer = require("ffi/blitbuffer")
        local rects = {}
        local fake = setmetatable({ shelf_scale = 1 }, { __index = DiscoverUI })
        local bb = {
            paintRect = function(_, _x, _y, _w, _h, color)
                table.insert(rects, color)
            end,
        }

        DiscoverUI._paintRailStackIndicator(fake, bb, 0, 1404, 100, 2, 4)
        assert.equals(4, #rects)
        assert.equals(tostring(Blitbuffer.COLOR_BLACK), tostring(rects[2]))
        assert.equals(tostring(Blitbuffer.COLOR_LIGHT_GRAY), tostring(rects[1]))

        rects = {}
        DiscoverUI._paintRailStackIndicator(fake, bb, 0, 1404, 100, 1, 1)
        assert.equals(0, #rects)
    end)

    it("keys remote covers by catalog id and local files by the home scheme", function()
        local fake = setmetatable({}, { __index = DiscoverUI })
        local remote_key = DiscoverUI._coverCacheKey(fake,
            { catalog_id = "/opds/cover/306" }, 100, 150)
        assert.equals("catalog:/opds/cover/306|100x150", remote_key)

        local local_key = DiscoverUI._coverCacheKey(fake,
            { file = "/downloads/a.epub" }, 100, 150)
        assert.equals("/downloads/a.epub|100x150", local_key)
    end)

    it("queues a thumbnail fetch on cover miss and serves the negative cache", function()
        local fake = setmetatable({
            _thumb_queue = {},
            _thumb_inflight = {},
        }, { __index = DiscoverUI })

        local entry = { catalog_id = "/opds/cover/306", thumb_href = "http://lib.example/opds/cover/306" }
        assert.is_nil(DiscoverUI._cachedCoverFor(fake, entry, 100, 150))
        assert.equals(1, #fake._thumb_queue)
        -- queued once, not per paint
        assert.is_nil(DiscoverUI._cachedCoverFor(fake, entry, 100, 150))
        assert.equals(1, #fake._thumb_queue)

        -- art-less entries cache the negative sentinel immediately
        local bare = { catalog_id = "/opds/cover/307" }
        assert.is_nil(DiscoverUI._cachedCoverFor(fake, bare, 100, 150))
        assert.is_false(fake.cover_cache["catalog:/opds/cover/307|100x150"])
    end)

    it("round-trips the download map and snapshot through plugin settings", function()
        local settings_file = "/tmp/bookshelf-discover-spec.lua"
        os.remove(settings_file)
        local plugin = setmetatable({
            settings_file = settings_file,
            ui = { document = nil },
        }, { __index = Bookshelf })

        -- the recorded file must exist for downloadedPath to confirm it
        local epub = "/tmp/bookshelf-discover-spec.epub"
        local f = io.open(epub, "w")
        f:write("x")
        f:close()

        Bookshelf.recordDownload(plugin, "/opds/cover/306", epub)
        assert.equals(epub, Bookshelf.downloadedPath(plugin, "/opds/cover/306"))

        Bookshelf.saveDiscoverSnapshot(plugin, SNAPSHOT)
        assert.equals(1760000000, Bookshelf.discoverSnapshot(plugin).fetched_at)

        -- a second plugin instance reads the persisted state cold
        local reloaded = setmetatable({
            settings_file = settings_file,
            ui = { document = nil },
        }, { __index = Bookshelf })
        assert.equals(epub, Bookshelf.downloadedPath(reloaded, "/opds/cover/306"))
        assert.equals(1760000000, Bookshelf.discoverSnapshot(reloaded).fetched_at)

        -- pruning drops entries whose file vanished
        os.remove(epub)
        local pruned = setmetatable({
            settings_file = settings_file,
            ui = { document = nil },
        }, { __index = Bookshelf })
        assert.is_nil(Bookshelf.downloadedPath(pruned, "/opds/cover/306"))

        os.remove(settings_file)
    end)

    it("removes a download, retiring every key that points at the path", function()
        local settings_file = "/tmp/bookshelf-discover-remove-spec.lua"
        os.remove(settings_file)
        local plugin = setmetatable({
            settings_file = settings_file,
            ui = { document = nil },
        }, { __index = Bookshelf })

        local epub = "/tmp/bookshelf-discover-remove-spec.epub"
        local f = io.open(epub, "w")
        f:write("x")
        f:close()

        -- the same path reachable under a legacy and a current key
        Bookshelf.recordDownload(plugin, "/opds/cover/305", epub)
        Bookshelf.recordDownload(plugin, "/opds/download/305/epub/", epub)

        -- reverse lookup finds a key for the file (either of the two)
        assert.is_truthy(Bookshelf.catalogIdForFile(plugin, epub))
        assert.is_nil(Bookshelf.catalogIdForFile(plugin, "/tmp/elsewhere.epub"))

        local removed = Bookshelf.removeDownload(plugin, "/opds/download/305/epub/")
        assert.equals(epub, removed)
        -- the file is gone and BOTH keys retired
        assert.is_nil(io.open(epub, "r"))
        assert.is_nil(Bookshelf.downloadedPath(plugin, "/opds/download/305/epub/"))
        assert.is_nil(Bookshelf.downloadedPath(plugin, "/opds/cover/305"))
        assert.is_nil(Bookshelf.catalogIdForFile(plugin, epub))

        -- removing an unknown id is a quiet no-op
        assert.is_nil(Bookshelf.removeDownload(plugin, "/opds/download/999/epub/"))

        os.remove(settings_file)
    end)

    it("migrates legacy thumb-path download keys on resolve", function()
        local settings_file = "/tmp/bookshelf-discover-migrate-spec.lua"
        os.remove(settings_file)
        local plugin = setmetatable({
            settings_file = settings_file,
            ui = { document = nil },
        }, { __index = Bookshelf })

        local epub = "/tmp/bookshelf-discover-migrate-spec.epub"
        local f = io.open(epub, "w")
        f:write("x")
        f:close()

        -- a pre-identity-fix map entry, keyed by the thumbnail's path
        Bookshelf.recordDownload(plugin, "/opds/cover/305", epub)

        -- resolving under the acquisition key finds it and re-keys it
        local resolved = Bookshelf.resolveDownload(plugin,
            "/opds/download/305/epub/", "/opds/cover/305")
        assert.equals(epub, resolved)
        assert.equals(epub, Bookshelf.downloadedPath(plugin, "/opds/download/305/epub/"))
        assert.is_nil(Bookshelf.downloadedPath(plugin, "/opds/cover/305"))

        -- a missing current key never destroys the legacy entry
        Bookshelf.recordDownload(plugin, "/opds/cover/999", epub)
        assert.equals(epub, Bookshelf.resolveDownload(plugin, nil, "/opds/cover/999"))
        assert.equals(epub, Bookshelf.downloadedPath(plugin, "/opds/cover/999"))

        os.remove(epub)
        os.remove(settings_file)
    end)

    it("includes Discover in the shared nav and marks it active on the surface", function()
        local fake = setmetatable({}, { __index = LibraryUI })
        local items = LibraryUI._navItems(fake)
        local ids = {}
        for _i, item in ipairs(items) do
            ids[item.id] = true
        end
        assert.is_true(ids.nav_discover)
        assert.is_nil(ids.nav_add)
        assert.equals("nav_discover", DiscoverUI.active_nav_tab)
    end)
end)
