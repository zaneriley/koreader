describe("Bookshelf icons", function()
    setup(function()
        require("commonrequire")
    end)

    it("paints the shared icon set without text dependencies", function()
        local Icons = dofile("plugins/bookshelf.koplugin/icons.lua")
        local rect_calls = 0
        local bb = {
            blitFrom = function()
                rect_calls = rect_calls + 1
            end,
            lightenRect = function()
                rect_calls = rect_calls + 1
            end,
            paintRect = function()
                rect_calls = rect_calls + 1
            end,
        }

        for _, name in ipairs({
            "library",
            "dictionary",
            "document",
            "add",
            "files",
            "open_book",
            "search",
            "filter",
            "more",
            "chevron_right",
        }) do
            Icons.paint(bb, name, 0, 0, 24, { selected = name == "library" })
        end

        assert.is_true(rect_calls > 0)
    end)
end)
