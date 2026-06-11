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
            new = { title = "Recently added Books", rows = {
                {
                    title = "Difficult Conversations",
                    author = "Sheila Heen",
                    text = "Difficult Conversations - Sheila Heen",
                    epub_href = "http://lib.example/opds/download/306/epub/",
                    thumb_href = "http://lib.example/opds/cover/306",
                    catalog_id = "/opds/cover/306",
                },
            } },
            hot = { title = "Hot Books", rows = {} },
        },
    }

    it("builds rail entries from a snapshot with on-device resolution", function()
        local fake = setmetatable({
            plugin = {
                downloadedPath = function(_, catalog_id)
                    if catalog_id == "/opds/cover/306" then
                        return "/downloads/difficult.epub"
                    end
                end,
            },
        }, { __index = DiscoverUI })

        local rails = DiscoverUI._railsFromSnapshot(fake, SNAPSHOT)

        assert.equals(1, #rails.new)
        assert.equals(0, #rails.hot)
        local entry = rails.new[1]
        assert.equals("Difficult Conversations", entry.display_title)
        assert.equals("Sheila Heen", entry.authors)
        assert.equals("/downloads/difficult.epub", entry.file) -- on-device mark
        assert.is_function(entry.callback) -- card tap opens the panel
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
