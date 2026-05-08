local Blitbuffer = require("ffi/blitbuffer")
local has_icon_widget, IconWidget = pcall(require, "ui/widget/iconwidget")

local Icons = {}

local asset_icons = {
    add = "plus",
    chevron_right = "chevron.right",
    files = "appbar.filebrowser",
    open_book = "book.opened",
    search = "appbar.search",
}

local function round(value)
    return math.floor(value + 0.5)
end

local function stroke(size, requested)
    return math.max(1, requested or round(size * 0.06))
end

local function rectBorder(bb, x, y, w, h, line, color)
    bb:paintRect(x, y, w, line, color)
    bb:paintRect(x, y + h - line, w, line, color)
    bb:paintRect(x, y, line, h, color)
    bb:paintRect(x + w - line, y, line, h, color)
end

local function geometry(x, y, size)
    local function px(fraction)
        return round(size * fraction)
    end
    local function rect(rx, ry, rw, rh)
        return x + px(rx), y + px(ry), px(rw), px(rh)
    end
    return px, rect
end

local function colorFor(opts)
    opts = opts or {}
    if opts.color then
        return opts.color
    elseif opts.selected then
        return Blitbuffer.COLOR_BLACK
    end
    return opts.inactive_color or Blitbuffer.COLOR_DARK_GRAY
end

local function paintAsset(bb, name, x, y, size, opts)
    if not has_icon_widget or not asset_icons[name] then
        return false
    end

    local widget = IconWidget:new{
        icon = asset_icons[name],
        width = size,
        height = size,
        dim = not opts.selected,
    }
    local ok = pcall(function()
        widget:paintTo(bb, x, y)
    end)
    if widget.free then
        widget:free()
    end
    return ok
end

local function paintChevronRight(bb, x, y, size, line, color)
    local start_x = x + round(size * 0.34)
    local mid_y = y + round(size * 0.50)
    local step = math.max(1, round(size * 0.12))
    local steps = math.max(3, math.floor(size * 0.28 / step) + 1)
    for i = 0, steps - 1 do
        bb:paintRect(start_x + i * step, mid_y - (steps - i) * step, line, line, color)
        bb:paintRect(start_x + i * step, mid_y + (steps - i - 1) * step, line, line, color)
    end
end

function Icons.paint(bb, name, x, y, size, opts)
    opts = opts or {}
    if paintAsset(bb, name, x, y, size, opts) then
        return
    end

    local color = colorFor(opts)
    local line = stroke(size, opts.line)
    local px, rect = geometry(x, y, size)
    local center_y = y + math.floor(size / 2)

    if name == "search" then
        local lens = math.floor(size * 0.48)
        local lens_x = x + math.floor(size * 0.16)
        local lens_y = y + math.floor(size * 0.12)
        rectBorder(bb, lens_x, lens_y, lens, lens, line, color)
        for i = 0, math.max(2, round(size * 0.18)) do
            bb:paintRect(lens_x + lens - line + i, lens_y + lens - line + i, line, line, color)
        end
    elseif name == "filter" then
        local top = y + math.floor(size * 0.26)
        local widths = { px(0.58), px(0.40), px(0.22) }
        for i, width in ipairs(widths) do
            bb:paintRect(x + math.floor((size - width) / 2), top + (i - 1) * px(0.22), width, line, color)
        end
    elseif name == "more" then
        local dot = math.max(1, math.floor(size * 0.11))
        local gap = px(0.18)
        local start = x + math.floor((size - dot * 3 - gap * 2) / 2)
        for i = 0, 2 do
            bb:paintRect(start + i * (dot + gap), center_y - math.floor(dot / 2), dot, dot, color)
        end
    elseif name == "chevron_right" then
        paintChevronRight(bb, x, y, size, line, color)
    elseif name == "dictionary" then
        local bx, by, bw, bh = rect(0.17, 0.05, 0.66, 0.90)
        rectBorder(bb, bx, by, bw, bh, line, color)
        bb:paintRect(bx + px(0.16), by + px(0.12), line, bh - px(0.24), color)
    elseif name == "document" then
        local bx, by, bw, bh = rect(0.22, 0.08, 0.56, 0.84)
        rectBorder(bb, bx, by, bw, bh, line, color)
        bb:paintRect(bx + px(0.14), by + px(0.28), bw - px(0.28), line, color)
        bb:paintRect(bx + px(0.14), by + px(0.44), bw - px(0.28), line, color)
    elseif name == "add" then
        local bx, by, bw, bh = rect(0.10, 0.10, 0.80, 0.80)
        rectBorder(bb, bx, by, bw, bh, line, color)
        bb:paintRect(x + math.floor(size / 2), y + px(0.28), line, px(0.44), color)
        bb:paintRect(x + px(0.28), y + math.floor(size / 2), px(0.44), line, color)
    elseif name == "files" then
        local folder_x = x + px(0.10)
        local folder_y = y + px(0.20)
        bb:paintRect(folder_x, folder_y, px(0.34), line, color)
        bb:paintRect(folder_x + px(0.30), folder_y + px(0.12), px(0.50), line, color)
        rectBorder(bb, folder_x, folder_y + px(0.18), px(0.80), px(0.52), line, color)
    else
        local bx, by, bw, bh = rect(0.15, 0.05, 0.70, 0.90)
        if opts.selected then
            bb:paintRect(bx, by, bw, bh, color)
            bb:paintRect(bx + px(0.17), by + px(0.12), line, bh - px(0.24), Blitbuffer.COLOR_WHITE)
        else
            rectBorder(bb, bx, by, bw, bh, line, color)
            bb:paintRect(bx + px(0.17), by + px(0.12), line, bh - px(0.24), color)
        end
    end
end

return Icons
