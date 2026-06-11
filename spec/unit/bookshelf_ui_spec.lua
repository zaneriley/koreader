describe("Bookshelf UI module", function()
    local Blitbuffer

    setup(function()
        require("commonrequire")
        Blitbuffer = require("ffi/blitbuffer")
    end)

    it("loads the componentized UI module", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")

        assert.is_table(LibraryUI)
        assert.is_function(LibraryUI.new)
    end)

    it("does not draw a border around book card text", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local GridLayout = dofile("plugins/bookshelf.koplugin/gridlayout.lua")
        local text_stack = {
            title_h = 28,
            metadata_h = 13,
            title_line_height = 0.12,
            metadata_line_height = 0.02,
        }
        local slot = GridLayout.grid("small", {
            x = 0,
            y = 20,
            w = 600,
            rows = 1,
            item_count = 1,
            scale = 1,
            text_stack = text_stack,
        }).slots[1]
        local border_calls = 0
        local cover_calls = 0
        local icon_sizes = {}
        local fake = setmetatable({
            shelf_scale = 1,
            _bookTextStack = function()
                return text_stack
            end,
            _paintPressedRect = function() end,
            _paintRectBorder = function()
                border_calls = border_calls + 1
            end,
            _paintBookCover = function()
                cover_calls = cover_calls + 1
            end,
            _paintTextBox = function() end,
            _paintIcon = function(_, _, _, _, _, size)
                table.insert(icon_sizes, size)
            end,
            _entryTitle = function()
                return "Quickstart Guide"
            end,
            _entryAuthor = function()
                return "Document"
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintBookCard(fake, {}, nil, slot, "book_1", { kind = "small" })

        assert.equals(1, cover_calls)
        assert.equals(0, border_calls)
        assert.equals(24, icon_sizes[1])
    end)

    it("places metadata from the resolved typography stack before paint", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local GridLayout = dofile("plugins/bookshelf.koplugin/gridlayout.lua")
        local text_stack = {
            title_h = 31,
            metadata_h = 13,
            title_line_height = 0.12,
            metadata_line_height = 0.02,
        }
        local slot = GridLayout.grid("small", {
            x = 0,
            y = 20,
            w = 600,
            rows = 1,
            item_count = 1,
            scale = 1,
            text_stack = text_stack,
        }).slots[1]
        local text_boxes = {}
        local fake = setmetatable({
            shelf_scale = 1,
            _bookTextStack = function()
                return text_stack
            end,
            _paintPressedRect = function() end,
            _paintBookCover = function() end,
            _paintTextBox = function(_, _, text, _, text_y, _, options)
                table.insert(text_boxes, {
                    text = text,
                    y = text_y,
                    height_adjust = options.height_adjust,
                    line_height = options.line_height,
                })
                if text == "Grimms' Fairy Tales" then
                    return { h = 99 }
                end
                return { h = 13 }
            end,
            _paintCenteredIcon = function() end,
            _zone = function() end,
            _entryTitle = function()
                return "Grimms' Fairy Tales"
            end,
            _entryAuthor = function()
                return "Jacob Grimm"
            end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintBookCard(fake, {}, {}, slot, "book_1", { kind = "small" })

        assert.equals("Grimms' Fairy Tales", text_boxes[1].text)
        assert.is_true(text_boxes[1].height_adjust)
        assert.equals(0.12, text_boxes[1].line_height)
        assert.equals("Jacob Grimm", text_boxes[2].text)
        assert.equals(slot.title.y + text_stack.title_h + 4, slot.metadata.y)
        assert.equals(slot.metadata.y, text_boxes[2].y)
        assert.is_true(text_boxes[2].height_adjust)
    end)

    it("clips carousel card hit zones to the visible rail bounds", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local GridLayout = dofile("plugins/bookshelf.koplugin/gridlayout.lua")
        local Geom = require("ui/geometry")
        local text_stack = {
            title_h = 28,
            metadata_h = 13,
            title_line_height = 0.12,
            metadata_line_height = 0.02,
        }
        local slot = GridLayout.rail("small", {
            x = 0,
            y = 0,
            w = 650,
            item_count = 6,
            scale = 1,
            text_stack = text_stack,
        }).slots[6]
        local fake = setmetatable({
            shelf_scale = 1,
            zones = {},
            _bookTextStack = function()
                return text_stack
            end,
            _paintPressedRect = function() end,
            _paintBookCover = function() end,
            _paintTextBox = function() end,
            _paintCenteredIcon = function() end,
            _entryTitle = function()
                return "Partly Visible"
            end,
            _entryAuthor = function()
                return "Document"
            end,
            _openEntry = function() end,
            _showMore = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintBookCard(fake, {}, {}, slot, "book_6", {
            kind = "small",
            clip_rect = Geom:new{x = 0, y = 0, w = 650, h = slot.h},
        })

        assert.equals(1, #fake.zones)
        assert.equals("book_6", fake.zones[1].id)
        assert.equals(616, fake.zones[1].rect.x)
        assert.equals(34, fake.zones[1].rect.w)
    end)

    it("uses a shaded fill for generated placeholder covers", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local fake = setmetatable({}, { __index = LibraryUI })

        assert.equals(tostring(Blitbuffer.COLOR_GRAY_E), tostring(LibraryUI._coverFillColor(fake, {})))
        assert.equals(tostring(Blitbuffer.COLOR_WHITE), tostring(LibraryUI._coverFillColor(fake, {
            cover_path = "/tmp/cover.png",
        })))
    end)

    it("paints the placeholder cover label without a text box", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local text_calls = {}
        local text_box_calls = 0
        local fake = setmetatable({
            shelf_scale = 1,
            _paintRectBorder = function() end,
            _hairline = function()
                return 1
            end,
            _coverFillColor = function()
                return Blitbuffer.COLOR_GRAY_E
            end,
            _entryTitle = function()
                return "Quickstart Guide"
            end,
            _entryAuthor = function()
                return nil
            end,
            _paintLine = function() end,
            _paintText = function(_, _, text)
                table.insert(text_calls, text)
            end,
            _paintTextBox = function()
                text_box_calls = text_box_calls + 1
            end,
        }, { __index = LibraryUI })
        local bb = {
            paintRect = function() end,
        }

        LibraryUI._paintBookCover(fake, bb, {}, 0, 0, 148, 222, "large")

        assert.equals(0, text_box_calls)
        assert.equals("Document", text_calls[#text_calls])
    end)

    it("paints cached cover artwork instead of generated placeholder text", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local text_calls = 0
        local blit_calls = {}
        local fake_cover = {}
        local fake = setmetatable({
            shelf_scale = 1,
            _paintRectBorder = function() end,
            _hairline = function()
                return 1
            end,
            _coverFillColor = function()
                return Blitbuffer.COLOR_WHITE
            end,
            _cachedCoverFor = function()
                return { bb = fake_cover, w = 80, h = 120 }
            end,
            _paintText = function()
                text_calls = text_calls + 1
            end,
        }, { __index = LibraryUI })
        local bb = {
            paintRect = function() end,
            blitFrom = function(_, image, x, y, sx, sy, w, h)
                table.insert(blit_calls, { image = image, x = x, y = y, sx = sx, sy = sy, w = w, h = h })
            end,
        }

        LibraryUI._paintBookCover(fake, bb, { file = "/books/alice.epub" }, 0, 0, 104, 156, "small")

        assert.equals(0, text_calls)
        assert.equals(fake_cover, blit_calls[1].image)
        assert.equals(12, blit_calls[1].x)
        assert.equals(18, blit_calls[1].y)
        assert.equals(80, blit_calls[1].w)
        assert.equals(120, blit_calls[1].h)
    end)

    it("uses a taller padded empty state for continue reading", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local border_calls = {}
        local icon_calls = {}
        local text_calls = {}
        local text_options = {}
        local fake = setmetatable({
            shelf_scale = 1,
            _paintRectBorder = function(_, _, x, y, w, h)
                table.insert(border_calls, { x = x, y = y, w = w, h = h })
            end,
            _paintIcon = function(_, _, icon, x, y, size)
                table.insert(icon_calls, { icon = icon, x = x, y = y, size = size })
            end,
            _paintText = function(_, _, text, x, y, options)
                table.insert(text_calls, { text = text, x = x, y = y })
                table.insert(text_options, options or {})
            end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        local h = LibraryUI._paintContinueEmptyState(fake, {}, 16, 64, 568, 284)

        assert.equals(284, h)
        assert.equals(1, #border_calls)
        assert.equals(284, border_calls[1].h)
        assert.equals("open_book", icon_calls[1].icon)
        assert.equals(288, icon_calls[1].x)
        assert.equals(170, icon_calls[1].y)
        assert.equals(24, icon_calls[1].size)
        assert.equals("Nothing in progress yet", text_calls[1].text)
        assert.equals(32, text_calls[1].x)
        assert.equals("Start reading a book and it will appear here.", text_calls[2].text)
        assert.equals(13, text_options[1].size)
        assert.equals(536, text_options[1].width)
        assert.equals(9, text_options[2].size)
        assert.equals(536, text_options[2].width)
    end)

    it("uses the short library title", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")

        assert.equals("Library", LibraryUI.title)
    end)

    it("does not draw a decorative line around the page title", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local line_calls = 0
        local text_calls = {}
        local fake = setmetatable({
            shelf_scale = 1,
            title = "Library",
            _paintText = function(_, _, text)
                table.insert(text_calls, text)
                return { w = 96, h = 44 }
            end,
            _paintLine = function()
                line_calls = line_calls + 1
            end,
            _paintHeaderAction = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintHeader(fake, {}, 16, 48, 568)

        assert.equals("Library", text_calls[1])
        assert.equals(0, line_calls)
    end)

    it("uses one category header style for titles, counts, and controls", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local text_calls = {}
        local text_options = {}
        local fake = setmetatable({
            shelf_scale = 1,
            _paintPressedRect = function() end,
            _paintText = function(_, _, text, _, _, options)
                table.insert(text_calls, text)
                table.insert(text_options, options or {})
                return { w = #text * 7, h = 16 }
            end,
            _zone = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintCategoryHeader(fake, {}, {
            title = "All books",
            count_text = "9 items",
            controls = {{ label = "Sort:", value = "Recent", width = 112 }}, -- unscaled_size_check: ignore
            x = 16,
            y = 48,
            w = 420,
            id = "all",
            callback = function() end,
        })

        assert.same({ "All books", "9 items", "Sort:", "Recent" }, text_calls)
        for _, options in ipairs(text_options) do
            assert.equals(13, options.size)
        end
        assert.equals("NotoSans-Bold.ttf", text_options[1].face)
        assert.equals("NotoSans-Regular.ttf", text_options[2].face)
        assert.equals("NotoSans-Regular.ttf", text_options[3].face)
        assert.equals("NotoSans-Bold.ttf", text_options[4].face)
    end)

    it("right-aligns category controls inside the safe header width", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local text_calls = {}
        local widths = {
            ["All books"] = 56,
            ["52 items"] = 54,
            ["Sort:"] = 31,
            Recent = 47,
        }
        local fake = setmetatable({
            shelf_scale = 1,
            _paintPressedRect = function() end,
            _textSize = function(_, text)
                return { w = widths[text] or 10, h = 16 }
            end,
            _paintText = function(_, _, text, text_x, _, options)
                table.insert(text_calls, {
                    text = text,
                    x = text_x,
                    max_width = options and options.max_width,
                })
                return { w = widths[text] or 10, h = 16 }
            end,
            _zone = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintCategoryHeader(fake, {}, {
            title = "All books",
            count_text = "52 items",
            controls = {{ label = "Sort:", value = "Recent", width = 112 }}, -- unscaled_size_check: ignore
            x = 16,
            y = 48,
            w = 568,
            id = "all",
            callback = function() end,
        })

        assert.same({ "All books", "52 items", "Sort:", "Recent" }, {
            text_calls[1].text,
            text_calls[2].text,
            text_calls[3].text,
            text_calls[4].text,
        })
        assert.equals(502, text_calls[3].x)
        assert.equals(537, text_calls[4].x)
        assert.equals(584, text_calls[4].x + text_calls[4].max_width)
    end)

    it("uses the shared icon system for section chevrons", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local text_calls = {}
        local text_options = {}
        local icon_calls = {}
        local fake = setmetatable({
            shelf_scale = 1,
            _paintPressedRect = function() end,
            _paintText = function(_, _, text, _, _, options)
                table.insert(text_calls, text)
                table.insert(text_options, options or {})
                return { w = 124, h = 22 }
            end,
            _paintIcon = function(_, _, icon, icon_x, icon_y, size)
                table.insert(icon_calls, { icon = icon, x = icon_x, y = icon_y, size = size })
            end,
            _zone = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintSectionHeader(fake, {}, "Recently added", nil, nil, 16, 48, 420, "recent", function() end)

        assert.equals(13, text_options[1].size)
        assert.equals("chevron_right", icon_calls[1].icon)
        assert.equals(146, icon_calls[1].x)
        assert.equals(47, icon_calls[1].y)
        assert.equals(24, icon_calls[1].size)
        for _, text in ipairs(text_calls) do
            assert.not_equals(">", text)
        end
    end)

    it("renders recently added through the shared category header component", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local header_calls = {}
        local fake = setmetatable({
            shelf_scale = 1,
            _recentlyAddedEntries = function()
                return {}
            end,
            _paintCategoryHeader = function(_, _, opts)
                table.insert(header_calls, opts)
            end,
            _paintEmptyShelfPlaceholder = function() end,
            _addBooks = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintRecentlyAdded(fake, {}, 0, 100, 600)

        assert.equals(1, #header_calls)
        assert.equals("Recently added", header_calls[1].title)
        assert.is_true(header_calls[1].chevron)
        assert.equals(16, header_calls[1].x)
        assert.equals(568, header_calls[1].w)
    end)

    it("renders continue reading through the shared category header component", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local header_calls = {}
        local fake = setmetatable({
            shelf_scale = 1,
            _continueEntry = function()
                return nil
            end,
            _paintCategoryHeader = function(_, _, opts)
                table.insert(header_calls, opts)
            end,
            _paintContinueEmptyState = function()
                return 284
            end,
            _continue = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintContinueShelf(fake, {}, 0, 100, 600)

        assert.equals(1, #header_calls)
        assert.equals("Continue reading", header_calls[1].title)
        assert.is_true(header_calls[1].chevron)
        assert.equals(16, header_calls[1].x)
        assert.equals(568, header_calls[1].w)
    end)

    it("paints the continue entry as a horizontal card capped at its natural height", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local card_call
        local fake = setmetatable({
            shelf_scale = 1,
            _continueEntry = function()
                return { title = "Alice" }
            end,
            _bookCardMetrics = function()
                return {
                    outer = 16,
                    gutter = 16,
                }
            end,
            _paintCategoryHeader = function() end,
            _paintContinueCard = function(_, _, _, x, y, w, h)
                card_call = { x = x, y = y, w = w, h = h }
                return h
            end,
            _continue = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        local shelf_h = LibraryUI._paintContinueShelf(fake, {}, 0, 100, 600, 360)

        -- card natural height: the large-card cover (148du * 3/2) + 16du padding * 2 = 254
        assert.equals(254, card_call.h)
        assert.equals(16, card_call.x)
        assert.equals(568, card_call.w)
        assert.equals(32 + 12 + 254, shelf_h)
    end)

    it("uses the horizontal card height for the continue body when an entry exists", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local fake = setmetatable({
            shelf_scale = 1,
            _continueEntry = function()
                return { title = "Alice" }
            end,
            _bookCardMetrics = function()
                return { gutter = 16 }
            end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        assert.equals(254, LibraryUI._continueShelfBodyHeight(fake))
    end)

    it("paints the resume snippet as quoted italic prose inside the continue card", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local boxes = {}
        local cover_call
        local fake = setmetatable({
            shelf_scale = 1,
            _bookCardMetrics = function()
                return { outer = 16, gutter = 16 }
            end,
            _paintPressedRect = function() end,
            _paintRectBorder = function() end,
            _paintBookCover = function(_, _, _, cx, cy, cw, ch)
                cover_call = { x = cx, y = cy, w = cw, h = ch }
            end,
            _paintCenteredIcon = function() end,
            _paintProgressLine = function() end,
            _paintText = function()
                return { w = 60, h = 14 }
            end,
            _paintTextBox = function(_, _, text, _, _, _, options)
                table.insert(boxes, { text = text, face = options.face })
                return { w = 100, h = 30 }
            end,
            _textSize = function()
                return { w = 50, h = 12 }
            end,
            _iconSize = function()
                return 24
            end,
            _zone = function() end,
            _continue = function() end,
            _showMore = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintContinueCard(fake, {}, {
            display_title = "Grimms' Fairy Tales",
            authors = "Jacob Grimm",
            percent_finished = 0.03,
            resume_snippet = "In the olden days, when wishing still helped",
        }, 0, 0, 600, 254)

        -- first box is the title, second is the snippet
        assert.equals(2, #boxes)
        assert.is_truthy(boxes[2].text:find("In the olden days", 1, true))
        assert.is_truthy(boxes[2].text:find("“", 1, true))
        -- the snippet uses the resolved italic serif voice, whichever face
        -- is installed in this environment
        assert.equals(LibraryUI._font_tokens.display_italic, boxes[2].face)

        -- without artwork, the placeholder cover box bleeds flush to the
        -- card's top, left, and bottom edges at the 2:3 ratio
        assert.equals(0, cover_call.x)
        assert.equals(0, cover_call.y)
        assert.equals(254, cover_call.h)
        assert.equals(169, cover_call.w)
    end)

    it("bleeds real cover art flush and sizes the text column from its width", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local blit
        local title_x
        local bb = {
            blitFrom = function(_, _, bx, by)
                blit = { x = bx, y = by }
            end,
        }
        local fake = setmetatable({
            shelf_scale = 1,
            _bookCardMetrics = function()
                return { outer = 16, gutter = 16 }
            end,
            _cachedCoverFor = function()
                return { bb = "cover", w = 150, h = 254 }
            end,
            _paintPressedRect = function() end,
            _paintRectBorder = function() end,
            _paintBookCover = function()
                error("placeholder path must not run when artwork exists")
            end,
            _paintCenteredIcon = function() end,
            _paintProgressLine = function() end,
            _paintText = function()
                return { w = 60, h = 14 }
            end,
            _paintTextBox = function(_, _, _, tx)
                title_x = title_x or tx
                return { w = 100, h = 30 }
            end,
            _textSize = function()
                return { w = 50, h = 12 }
            end,
            _iconSize = function()
                return 24
            end,
            _zone = function() end,
            _continue = function() end,
            _showMore = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintContinueCard(fake, bb, {
            display_title = "Grimms' Fairy Tales",
            percent_finished = 0.03,
        }, 0, 0, 600, 254)

        assert.equals(0, blit.x)
        assert.equals(0, blit.y)
        -- text column starts after the art's real width plus the 24du gap
        assert.equals(150 + 24, title_x)
    end)

    it("memoizes the continue entry within one paint cycle", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local provider_calls = 0
        local fake = setmetatable({
            _paint_cache = {},
            _providerEntry = function()
                provider_calls = provider_calls + 1
                return { file = "/downloads/book.epub", title = "Book" }
            end,
            _normalizeContinueEntry = function(_, entry)
                return entry
            end,
        }, { __index = LibraryUI })

        local first = LibraryUI._continueEntry(fake)
        local second = LibraryUI._continueEntry(fake)

        assert.equals(1, provider_calls)
        assert.equals(first, second)
    end)

    it("skips the progress block for a book with no reading state", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local bar_calls = 0
        local fake = setmetatable({
            shelf_scale = 1,
            _bookCardMetrics = function()
                return { outer = 16, gutter = 16 }
            end,
            _paintPressedRect = function() end,
            _paintRectBorder = function() end,
            _paintBookCover = function() end,
            _paintCenteredIcon = function() end,
            _paintProgressLine = function()
                bar_calls = bar_calls + 1
            end,
            _paintText = function()
                return { w = 60, h = 14 }
            end,
            _paintTextBox = function()
                return { w = 100, h = 30 }
            end,
            _textSize = function()
                return { w = 50, h = 12 }
            end,
            _iconSize = function()
                return 24
            end,
            _zone = function() end,
            _continue = function() end,
            _showMore = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintContinueCard(fake, {}, {
            display_title = "Untouched Book",
            status = "new",
        }, 0, 0, 600, 254)

        assert.equals(0, bar_calls)
    end)

    it("searches device library entries by title and author, case-insensitively", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local fake = setmetatable({
            _libraryEntries = function()
                return {
                    { display_title = "Difficult Conversations", authors = "Sheila Heen" },
                    { display_title = "Peopleware", authors = "Tom DeMarco" },
                    { display_title = "陰翳礼讃", authors = "谷崎潤一郎" },
                }
            end,
        }, { __index = LibraryUI })

        assert.equals(1, #LibraryUI._searchLibraryEntries(fake, "conversations"))
        assert.equals(1, #LibraryUI._searchLibraryEntries(fake, "HEEN"))
        assert.equals(1, #LibraryUI._searchLibraryEntries(fake, "ware"))
        assert.equals(1, #LibraryUI._searchLibraryEntries(fake, "礼讃"))
        assert.equals(0, #LibraryUI._searchLibraryEntries(fake, ""))
        assert.equals(0, #LibraryUI._searchLibraryEntries(fake, "   "))
        assert.equals(0, #LibraryUI._searchLibraryEntries(fake, "zzz"))
    end)

    it("opens the OPDS catalog and refreshes the shelf when it closes", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local UIManager = require("ui/uimanager")
        local orig_set_dirty = UIManager.setDirty
        local dirtied = false
        UIManager.setDirty = function() dirtied = true end

        local browser = {}
        local extracted = false
        local opds = {
            onShowOPDSCatalog = function(self)
                self.opds_browser = browser
            end,
        }
        local fake = setmetatable({
            ui = { opds = opds },
            _closed = false,
            dimen = {},
            _triggerBackgroundExtraction = function()
                extracted = true
            end,
            _showInfo = function()
                error("placeholder must not show when OPDS is reachable")
            end,
        }, { __index = LibraryUI })

        LibraryUI._addBooks(fake)

        -- the catalog opened (its browser was built) and its close_callback
        -- was wrapped; closing refreshes the shelf for the new download
        assert.is_truthy(browser.close_callback)
        browser.close_callback()
        assert.is_true(extracted)
        assert.is_true(dirtied)

        UIManager.setDirty = orig_set_dirty
    end)

    it("shows a placeholder when no OPDS source is reachable", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local shown
        local fake = setmetatable({
            ui = {},
            _showInfo = function(_, text)
                shown = text
            end,
        }, { __index = LibraryUI })

        LibraryUI._addBooks(fake)

        assert.is_truthy(shown)
    end)

    it("uses shared layout spacing tokens for shelf positioning", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local fake = setmetatable({
            shelf_scale = 1,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        assert.equals(32, LibraryUI._sectionHeaderHeight(fake))
        assert.equals(12, LibraryUI._sectionGap(fake))
        assert.equals(24, LibraryUI._titleToShelfGap(fake))
        assert.equals(32, LibraryUI._continueToLowerGap(fake))
        assert.equals(32, LibraryUI._lowerShelfGap(fake))
        assert.equals(16, LibraryUI._lowerBottomMargin(fake))
    end)

    it("flows the lower shelves below continue reading and gives all books the slack", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local fake = setmetatable({
            shelf_scale = 1,
            _continueEntry = function()
                return nil
            end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        local layout = LibraryUI._shelfStackLayout(fake, 200, 1300)

        assert.equals(200, layout.continue_y)
        assert.equals(328, layout.continue_h)
        assert.equals(328, layout.recent_h)
        assert.equals(560, layout.recent_y)
        assert.equals(layout.continue_y + layout.continue_h + layout.continue_gap, layout.recent_y)
        assert.equals(920, layout.all_y)
        assert.equals(364, layout.all_h)
        assert.equals(724, layout.lower_stack_h)
        assert.equals(1284, layout.all_y + layout.all_h)
        assert.equals(1300, layout.all_y + layout.all_h + layout.bottom_margin)
        assert.is_false(layout.continue_shrunk)
    end)

    it("shrinks continue reading when the lower stack needs bottom-nav space", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local fake = setmetatable({
            shelf_scale = 1,
            _continueEntry = function()
                return nil
            end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        local layout = LibraryUI._shelfStackLayout(fake, 200, 1130)

        assert.equals(264, layout.continue_h)
        assert.equals(496, layout.recent_y)
        assert.equals(856, layout.all_y)
        assert.equals(1114, layout.all_y + layout.all_h)
        assert.equals(1130, layout.all_y + layout.all_h + layout.bottom_margin)
        assert.is_true(layout.continue_shrunk)
    end)

    it("keeps lower shelves below continue reading when the viewport is cramped", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local fake = setmetatable({
            shelf_scale = 1,
            _continueEntry = function()
                return {}
            end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        local layout = LibraryUI._shelfStackLayout(fake, 200, 1000)

        assert.equals(160, layout.continue_h)
        assert.equals(392, layout.recent_y)
        assert.equals(layout.continue_y + layout.continue_h + layout.continue_gap, layout.recent_y)
        assert.is_true(layout.continue_shrunk)
    end)

    it("centers 24px header icons inside larger tap targets", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local pressed = {}
        local icons = {}
        local zones = {}
        local fake = setmetatable({
            shelf_scale = 1,
            _paintPressedRect = function(_, _, id, x, y, w, h)
                table.insert(pressed, { id = id, x = x, y = y, w = w, h = h })
            end,
            _paintIcon = function(_, _, icon, x, y, size)
                table.insert(icons, { icon = icon, x = x, y = y, size = size })
            end,
            _zone = function(_, id, rect)
                table.insert(zones, { id = id, rect = rect })
            end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintHeaderAction(fake, {}, "search", "search", 100, 50, 40, function() end)

        assert.equals(40, pressed[1].w)
        assert.equals(40, pressed[1].h)
        assert.equals("search", icons[1].icon)
        assert.equals(108, icons[1].x)
        assert.equals(58, icons[1].y)
        assert.equals(24, icons[1].size)
        assert.equals(40, zones[1].rect.w)
        assert.equals(40, zones[1].rect.h)
    end)

    it("uses the category header for all books and omits the view control", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local header_calls = {}
        local fake = setmetatable({
            shelf_scale = 1,
            dimen = { x = 0, w = 600 },
            library_page = 1,
            _libraryEntries = function()
                return {}
            end,
            _paintLine = function() end,
            _paintCategoryHeader = function(_, _, opts)
                table.insert(header_calls, opts)
            end,
            _paintEmptyShelfPlaceholder = function() end,
            _showFilter = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintAllBooks(fake, {}, 0, 100, 600, 260)

        assert.equals("All books", header_calls[1].title)
        assert.equals("0 items", header_calls[1].count_text)
        assert.equals(1, #header_calls[1].controls)
        assert.equals("Sort:", header_calls[1].controls[1].label)
        assert.equals("Recent", header_calls[1].controls[1].value)
    end)

    it("pages all books as a peeking rail that signals more books", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local card_calls = {}
        local fake = setmetatable({
            shelf_scale = 1,
            dimen = { x = 0, w = 650 },
            library_page = 1,
            _libraryEntries = function()
                return {
                    { title = "One" },
                    { title = "Two" },
                    { title = "Three" },
                    { title = "Four" },
                    { title = "Five" },
                    { title = "Six" },
                }
            end,
            _paintLine = function() end,
            _paintCategoryHeader = function() end,
            _paintBookCard = function(_, _, _, slot, _, options)
                table.insert(card_calls, { slot = slot, scale = options.scale })
            end,
            _showFilter = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintAllBooks(fake, {}, 0, 100, 650, 260)

        -- 650 wide fits 5 full small cards; the 6th is deliberately sliced at
        -- the edge as the swipe affordance, and the page steps by 5.
        assert.equals(6, #card_calls)
        assert.equals(104, card_calls[1].slot.w)
        assert.equals(1, card_calls[1].scale)
        assert.equals(16, card_calls[1].slot.x)
        assert.equals(616, card_calls[6].slot.x)
        assert.is_true(card_calls[6].slot.x + card_calls[6].slot.w > 650)
        assert.equals(1, #fake.rail_regions)
        assert.equals("all_books", fake.rail_regions[1].id)
        assert.equals(5, fake.rail_regions[1].step_count)
    end)

    it("pages recently added as a snapped carousel rail", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local entries = {}
        local card_calls = {}
        for i = 1, 10 do
            entries[i] = { title = "Book " .. tostring(i) }
        end
        local text_stack = {
            title_h = 32,
            metadata_h = 14,
            title_line_height = 0.12,
            metadata_line_height = 0.02,
        }
        local fake = setmetatable({
            shelf_scale = 1,
            dimen = { x = 0, w = 746 },
            rail_state = {
                recently_added = { page = 2 },
            },
            _recentlyAddedEntries = function()
                return entries
            end,
            _bookTextStack = function()
                return text_stack
            end,
            _paintSectionHeader = function() end,
            _paintBookCard = function(_, _, entry, slot, id, options)
                table.insert(card_calls, {
                    entry = entry,
                    slot = slot,
                    id = id,
                    clip_rect = options.clip_rect,
                })
            end,
            _addBooks = function() end,
            _px = function(_, value)
                return value
            end,
        }, { __index = LibraryUI })

        LibraryUI._paintRecentlyAdded(fake, {}, 0, 100, 746)

        assert.equals(4, #card_calls)
        assert.equals("Book 7", card_calls[1].entry.title)
        assert.equals("recent_7", card_calls[1].id)
        assert.equals(100 + 32 + 12, card_calls[1].clip_rect.y)
        assert.equals(1, #fake.rail_regions)
        assert.equals("recently_added", fake.rail_regions[1].id)
        assert.equals(2, fake.rail_regions[1].page)
        assert.equals(2, fake.rail_regions[1].max_page)
        assert.equals(6, fake.rail_regions[1].step_count)
    end)

    it("routes horizontal swipes to the rail under the gesture start point", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local Geom = require("ui/geometry")
        local UIManager = require("ui/uimanager")
        local BD = require("ui/bidi")
        local old_mirrored = BD._mirrored_ui_layout
        local recent_rect = Geom:new{x = 0, y = 100, w = 600, h = 180}
        local all_rect = Geom:new{x = 0, y = 400, w = 600, h = 160}
        local dirty_calls = {}
        local fake = setmetatable({
            rail_state = {
                recently_added = { page = 1 },
                all_books = { page = 2 },
            },
            rail_regions = {
                { id = "recently_added", rect = recent_rect, max_page = 3 },
                { id = "all_books", rect = all_rect, max_page = 4 },
            },
            library_page = 2,
        }, { __index = LibraryUI })

        stub(UIManager, "setDirty", function(_, widget, refresh_type, rect)
            table.insert(dirty_calls, {
                widget = widget,
                refresh_type = refresh_type,
                rect = rect,
            })
        end)

        assert.is_true(LibraryUI.onSwipe(fake, nil, {
            direction = "west",
            pos = Geom:new{x = 24, y = 120},
        }))
        assert.equals(2, fake.rail_state.recently_added.page)
        assert.equals(2, fake.rail_state.all_books.page)
        assert.equals(recent_rect, dirty_calls[1].rect)

        assert.is_false(LibraryUI.onSwipe(fake, nil, {
            direction = "west",
            pos = Geom:new{x = 24, y = 320},
        }))
        assert.equals(1, #dirty_calls)

        BD._mirrored_ui_layout = true
        local handled = LibraryUI.onSwipe(fake, nil, {
            direction = "west",
            pos = Geom:new{x = 24, y = 420},
        })
        BD._mirrored_ui_layout = old_mirrored
        UIManager.setDirty:revert()

        assert.is_true(handled)
        assert.equals(1, fake.rail_state.all_books.page)
        assert.equals(1, fake.library_page)
        assert.equals(all_rect, dirty_calls[2].rect)
    end)

    it("opens the file manager as an overlay when Bookshelf is the host", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local close_calls = 0
        local shown_path
        local fake = setmetatable({
            ui = {
                showFileManager = function(_, path)
                    shown_path = path
                end,
            },
            closeBookshelf = function()
                close_calls = close_calls + 1
            end,
        }, { __index = LibraryUI })

        LibraryUI._showFiles(fake, "/downloads/book.epub")

        assert.equals(0, close_calls)
        assert.equals("/downloads/book.epub", shown_path)
    end)

    it("opens a temporary file manager above Library when Library was opened from FileManager", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local FileManager = require("apps/filemanager/filemanager")
        local old_instance = FileManager.instance
        local close_calls = 0
        local host_close_calls = 0
        local shown_path
        local opened_filemanager
        local host_filemanager = {
            file_chooser = {
                path = "/downloads",
                changeToPath = function()
                    error("Library should not reveal the host FileManager")
                end,
            },
            onClose = function()
                host_close_calls = host_close_calls + 1
                FileManager.instance = nil
            end,
        }
        local fake = setmetatable({
            ui = host_filemanager,
            closeBookshelf = function()
                close_calls = close_calls + 1
            end,
        }, { __index = LibraryUI })
        FileManager.instance = host_filemanager

        stub(FileManager, "showFiles", function(_, path)
            shown_path = path
            opened_filemanager = {}
            FileManager.instance = opened_filemanager
        end)

        LibraryUI._showFiles(fake)

        assert.is_true(opened_filemanager.return_to_previous_view)
        FileManager.showFiles:revert()
        FileManager.instance = old_instance

        assert.equals(0, close_calls)
        assert.equals(1, host_close_calls)
        assert.equals("/downloads", shown_path)
    end)

    it("closes Library when a reader or explicit File browser action takes over", function()
        local LibraryUI = dofile("plugins/bookshelf.koplugin/ui.lua")
        local close_calls = 0
        local fake = setmetatable({
            closeBookshelf = function()
                close_calls = close_calls + 1
            end,
        }, { __index = LibraryUI })

        assert.is_true(LibraryUI.onShowingReader(fake))
        assert.is_true(LibraryUI.onShowFileManager(fake))
        assert.equals(2, close_calls)
    end)
end)
