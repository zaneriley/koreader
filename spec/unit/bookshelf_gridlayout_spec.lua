describe("Bookshelf grid layout", function()
    local GridLayout

    setup(function()
        GridLayout = dofile("plugins/bookshelf.koplugin/gridlayout.lua")
    end)

    it("renders no card slots for empty grids", function()
        local grid = GridLayout.grid("small", {
            x = 0,
            y = 0,
            w = 600,
            rows = 1,
            item_count = 0,
            scale = 1,
        })

        assert.equals(4, grid.columns)
        assert.equals(4, grid.capacity)
        assert.equals(0, #grid.slots)
    end)

    it("keeps one book in the first column without stretching", function()
        local one = GridLayout.grid("small", {
            x = 0,
            y = 0,
            w = 600,
            rows = 1,
            item_count = 1,
            scale = 1,
        })
        local full = GridLayout.grid("small", {
            x = 0,
            y = 0,
            w = 600,
            rows = 1,
            item_count = 5,
            scale = 1,
        })

        assert.equals(1, #one.slots)
        assert.equals(16, one.slots[1].x)
        assert.equals(104, one.slots[1].w)
        assert.equals(214, one.slots[1].h)
        assert.equals(one.slots[1].title.y + one.slots[1].title.h, one.slots[1].menu.y)
        assert.equals(one.slots[1].title.y + one.slots[1].title.h + 4, one.slots[1].metadata.y)
        assert.equals(full.slots[1].x, one.slots[1].x)
        assert.equals(full.slots[1].w, one.slots[1].w)
        assert.equals(full.slots[1].cover.w, one.slots[1].cover.w)
        assert.equals(full.slots[1].cover.h, one.slots[1].cover.h)
    end)

    it("left-aligns partial rows without redistributing columns", function()
        local grid = GridLayout.grid("small", {
            x = 0,
            y = 0,
            w = 600,
            rows = 1,
            item_count = 3,
            scale = 1,
        })

        assert.equals(3, #grid.slots)
        assert.equals(16, grid.slots[1].x)
        assert.equals(136, grid.slots[2].x)
        assert.equals(256, grid.slots[3].x)
        assert.equals(104, grid.slots[1].w)
        assert.equals(grid.slots[1].w, grid.slots[2].w)
        assert.equals(grid.slots[2].w, grid.slots[3].w)
    end)

    it("keeps the same fixed gutter across large and small grids", function()
        local large = GridLayout.metrics("large", 1)
        local small = GridLayout.metrics("small", 1)
        local narrow = GridLayout.grid("small", {
            x = 0,
            y = 0,
            w = 600,
            rows = 1,
            item_count = 4,
            scale = 1,
        })
        local exact_five = GridLayout.grid("small", {
            x = 0,
            y = 0,
            w = 616,
            rows = 1,
            item_count = 5,
            scale = 1,
        })

        assert.equals(16, large.gutter)
        assert.equals(large.gutter, small.gutter)
        assert.equals(4, narrow.columns)
        assert.equals(5, exact_five.columns)
        assert.equals(136, exact_five.slots[2].x)
        assert.equals(600, exact_five.slots[5].x + exact_five.slots[5].w)
    end)

    it("derives rail scale for featured shelves without changing fixed-scale rails", function()
        local large_scale = GridLayout.railScale("large", 746, {
            full_count = 4,
            peek = 0.5,
        })
        local large = GridLayout.rail("large", {
            x = 0,
            y = 0,
            w = 746,
            item_count = 6,
            full_count = 4,
            peek = 0.5,
        })
        local small = GridLayout.rail("small", {
            x = 0,
            y = 0,
            w = 650,
            item_count = 7,
            scale = 1,
        })

        assert.equals(1, large_scale)
        assert.equals(5, #large.slots)
        assert.equals(16, large.slots[1].x)
        assert.equals(508, large.slots[4].x)
        assert.equals(672, large.slots[5].x)
        assert.is_true(large.slots[5].x < large.right_edge)
        assert.is_true(large.slots[5].x + large.slots[5].w > large.right_edge)
        assert.equals(6, #small.slots)
        assert.equals(616, small.slots[6].x)
        assert.equals(104, small.slots[6].w)
        assert.is_true(small.slots[6].x < small.right_edge)
        assert.is_true(small.slots[6].x + small.slots[6].w > small.right_edge)
    end)

    it("derives snapped carousel windows from visible slots and page steps", function()
        local first = GridLayout.pageWindow(10, 5, 1, 4)
        local middle = GridLayout.pageWindow(10, 5, 2, 4)
        local overflow = GridLayout.pageWindow(10, 5, 99, 4)
        local empty = GridLayout.pageWindow(0, 5, 1, 4)

        assert.equals(1, first.page)
        assert.equals(3, first.max_page)
        assert.equals(1, first.first)
        assert.equals(5, first.last)
        assert.equals(5, first.count)

        assert.equals(2, middle.page)
        assert.equals(5, middle.first)
        assert.equals(9, middle.last)

        assert.equals(3, overflow.page)
        assert.equals(9, overflow.first)
        assert.equals(10, overflow.last)
        assert.equals(2, overflow.count)

        assert.equals(1, empty.page)
        assert.equals(0, empty.count)
    end)

    it("wraps large shelves left-to-right, then top-to-bottom", function()
        local grid = GridLayout.grid("large", {
            x = 0,
            y = 0,
            w = 672,
            rows = 2,
            item_count = 8,
            scale = 1,
        })

        assert.equals(8, #grid.slots)
        assert.equals(1, grid.slots[1].row)
        assert.equals(4, grid.slots[4].col)
        assert.equals(2, grid.slots[5].row)
        assert.equals(1, grid.slots[5].col)
        assert.equals(16, grid.slots[5].x)
        assert.equals(308, grid.slots[5].y)
    end)

    it("keeps the cover ratio constant across grid types", function()
        local large = GridLayout.metrics("large", 1)
        local small = GridLayout.metrics("small", 1)
        local large_ratio = large.cover_h / large.cover_w
        local small_ratio = small.cover_h / small.cover_w

        assert.is_true(math.abs(large_ratio - small_ratio) < 0.01)
        assert.is_true(math.abs(large_ratio - 1.5) < 0.01)
        assert.equals(148, large.cover_w)
        assert.equals(222, large.cover_h)
        assert.equals(104, small.cover_w)
        assert.equals(156, small.cover_h)
    end)

    it("derives card height and text slots from resolved typography", function()
        local text_stack = {
            title_h = 50,
            metadata_h = 15,
            title_line_height = 0.12,
            metadata_line_height = 0.02,
        }
        local metrics = GridLayout.metrics("small", 1, text_stack)
        local grid = GridLayout.grid("small", {
            x = 0,
            y = 0,
            w = 616,
            rows = 1,
            item_count = 1,
            scale = 1,
            text_stack = text_stack,
        })
        local slot = grid.slots[1]

        assert.equals(235, metrics.card_h)
        assert.equals(50, metrics.title_h)
        assert.equals(15, metrics.metadata_h)
        assert.equals(0.12, metrics.title_line_height)
        assert.equals(162, slot.title.y)
        assert.equals(216, slot.metadata.y)
        assert.equals(slot.title.y + slot.title.h + metrics.title_to_metadata_gap, slot.metadata.y)
        assert.equals(slot.metadata.y + slot.metadata.h + metrics.text_bottom_slack, slot.y + slot.h)
        assert.equals(slot.y + slot.h - metrics.menu_h, slot.menu.y)
    end)

    it("keeps 24px card menu slots for the shared icon size", function()
        local large = GridLayout.metrics("large", 1)
        local small = GridLayout.metrics("small", 1)
        local grid = GridLayout.grid("small", {
            x = 0,
            y = 0,
            w = 616,
            rows = 1,
            item_count = 1,
            scale = 1,
        })

        assert.equals(24, large.menu_h)
        assert.equals(24, small.menu_h)
        assert.equals(24, grid.slots[1].menu.h)
        assert.equals(grid.slots[1].y + grid.slots[1].h - 24, grid.slots[1].menu.y)
    end)

    it("lays out bottom tabs as four padded 1fr columns", function()
        local nav = GridLayout.bottomTabs({
            x = 0,
            y = 100,
            w = 600,
            count = 4,
            scale = 1,
        })

        assert.equals(68, nav.h)
        assert.equals(16, nav.edge)
        assert.equals(10, nav.top)
        assert.equals(12, nav.bottom)
        assert.equals(24, nav.icon_size)
        assert.equals(5, nav.icon_label_gap)
        assert.equals(4, #nav.slots)
        assert.equals(16, nav.slots[1].x)
        assert.equals(158, nav.slots[2].x)
        assert.equals(300, nav.slots[3].x)
        assert.equals(442, nav.slots[4].x)
        assert.equals(142, nav.slots[1].w)
        assert.equals(584, nav.slots[4].x + nav.slots[4].w)
        assert.equals(nav.slots[1].x, nav.slots[1].tap.x)
        assert.equals(nav.slots[1].y, nav.slots[1].tap.y)
        assert.equals(nav.slots[1].w, nav.slots[1].tap.w)
        assert.equals(68, nav.slots[1].tap.h)
        assert.equals(100 + 10, nav.slots[1].icon.y)
        assert.equals(100 + 10 + 24 + 5, nav.slots[1].label.y)
        assert.equals(17, nav.slots[1].label.h)
        assert.equals(100 + 68 - 12, nav.slots[1].label.y + nav.slots[1].label.h)
    end)
end)
