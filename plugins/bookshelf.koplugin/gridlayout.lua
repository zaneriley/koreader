local GridLayout = {}

local COVER_RATIO_NUM = 3
local COVER_RATIO_DEN = 2

-- Cover height / cover width: the one shape the whole shelf system repeats.
GridLayout.cover_ratio = COVER_RATIO_NUM / COVER_RATIO_DEN

local SPECS = {
    large = {
        card_w = 148,
        card_h = 284,
        cover_w = 148,
        cover_title_gap = 6,
        title_h = 32,
        title_to_metadata_gap = 4,
        metadata_h = 14,
        menu_h = 24,
        text_bottom_slack = 4,
        outer = 16,
        gutter = 16,
        row_gap = 24,
        max_cols = 4,
        title_size = 12,
        metadata_size = 10,
    },
    small = {
        card_w = 104,
        card_h = 214,
        cover_w = 104,
        cover_title_gap = 6,
        title_h = 28,
        title_to_metadata_gap = 4,
        metadata_h = 13,
        menu_h = 24,
        text_bottom_slack = 4,
        outer = 16,
        gutter = 16,
        row_gap = 24,
        max_cols = 8,
        title_size = 12,
        metadata_size = 10,
    },
}

local function round(value)
    return math.floor(value + 0.5)
end

local function scaleValue(value, scale)
    return math.max(1, round(value * (scale or 1)))
end

local function scaleGap(value, scale)
    value = tonumber(value) or 0
    if value <= 0 then
        return 0
    end
    return scaleValue(value, scale)
end

local function metricValue(value, fallback, scale)
    value = tonumber(value)
    if value and value > 0 then
        return math.max(1, round(value))
    end
    return scaleValue(fallback, scale)
end

local function resolveTextStack(spec, scale, cover_h, text_stack)
    text_stack = text_stack or {}
    local cover_title_gap = metricValue(text_stack.cover_title_gap, spec.cover_title_gap, scale)
    local title_h = metricValue(text_stack.title_h, spec.title_h, scale)
    local title_to_metadata_gap = text_stack.title_to_metadata_gap ~= nil
        and metricValue(text_stack.title_to_metadata_gap, spec.title_to_metadata_gap, scale)
        or scaleGap(spec.title_to_metadata_gap, scale)
    local metadata_h = metricValue(text_stack.metadata_h, spec.metadata_h, scale)
    local text_bottom_slack = text_stack.text_bottom_slack ~= nil
        and metricValue(text_stack.text_bottom_slack, spec.text_bottom_slack, scale)
        or scaleGap(spec.text_bottom_slack, scale)
    local text_stack_h = cover_title_gap
        + title_h
        + title_to_metadata_gap
        + metadata_h
        + text_bottom_slack

    return {
        cover_title_gap = cover_title_gap,
        title_h = title_h,
        title_to_metadata_gap = title_to_metadata_gap,
        metadata_h = metadata_h,
        text_bottom_slack = text_bottom_slack,
        text_stack_h = text_stack_h,
        card_h = math.max(scaleValue(spec.card_h, scale), cover_h + text_stack_h),
        title_line_height = text_stack.title_line_height,
        metadata_line_height = text_stack.metadata_line_height,
    }
end

local function cardSlot(metrics, opts, index, col, row, x, y)
    local scale = opts.scale
    local title_y = y + metrics.cover_h + metrics.cover_title_gap
    local metadata_y = title_y + metrics.title_h + metrics.title_to_metadata_gap
    local menu_size = metrics.menu_h
    return {
        index = index,
        col = col,
        row = row,
        scale = metrics.scale,
        x = x,
        y = y,
        w = metrics.card_w,
        h = metrics.card_h,
        cover = {
            x = x,
            y = y,
            w = metrics.cover_w,
            h = metrics.cover_h,
        },
        title = {
            x = x + scaleValue(4, scale),
            y = title_y,
            w = metrics.card_w - scaleValue(8, scale),
            h = metrics.title_h,
        },
        metadata = {
            x = x + scaleValue(4, scale),
            y = metadata_y,
            w = metrics.card_w - scaleValue(8, scale) - menu_size,
            h = metrics.metadata_h,
        },
        menu = {
            x = x + metrics.card_w - menu_size,
            y = y + metrics.card_h - menu_size,
            w = menu_size,
            h = menu_size,
        },
    }
end

function GridLayout.scaleValue(value, scale)
    return scaleValue(value, scale)
end

function GridLayout.scaleForViewport(width, height)
    local w = tonumber(width) or 0
    local h = tonumber(height) or 0
    if w <= 0 or h <= 0 then
        return 1
    end

    -- 672du fits a four-column large shelf. 1166du fits the current home stack
    -- with two large shelves, one small shelf, header, and bottom navigation.
    return math.max(1, math.min(w / 672, h / 1166))
end

function GridLayout.spec(kind)
    return SPECS[kind]
end

function GridLayout.metrics(kind, scale, text_stack)
    local spec = assert(SPECS[kind], "unknown bookshelf grid kind: " .. tostring(kind))
    local cover_w = scaleValue(spec.cover_w, scale)
    local cover_h = scaleValue(spec.cover_w * COVER_RATIO_NUM / COVER_RATIO_DEN, scale)
    local stack = resolveTextStack(spec, scale, cover_h, text_stack)

    return {
        kind = kind,
        scale = scale or 1,
        card_w = scaleValue(spec.card_w, scale),
        card_h = stack.card_h,
        cover_w = cover_w,
        cover_h = cover_h,
        cover_title_gap = stack.cover_title_gap,
        title_h = stack.title_h,
        title_to_metadata_gap = stack.title_to_metadata_gap,
        metadata_h = stack.metadata_h,
        text_bottom_slack = stack.text_bottom_slack,
        text_stack_h = stack.text_stack_h,
        menu_h = scaleValue(spec.menu_h, scale),
        outer = scaleValue(spec.outer, scale),
        gutter = scaleValue(spec.gutter, scale),
        row_gap = scaleValue(spec.row_gap, scale),
        max_cols = spec.max_cols,
        title_size = spec.title_size,
        metadata_size = spec.metadata_size,
        title_line_height = stack.title_line_height,
        metadata_line_height = stack.metadata_line_height,
    }
end

function GridLayout.columns(kind, width, scale, text_stack)
    local metrics = GridLayout.metrics(kind, scale, text_stack)
    local available = math.max(0, (tonumber(width) or 0) - metrics.outer * 2)
    if available < metrics.card_w then
        return 1
    end
    local cols = math.floor((available + metrics.gutter) / (metrics.card_w + metrics.gutter))
    return math.max(1, math.min(metrics.max_cols, cols))
end

function GridLayout.rowsForHeight(kind, height, scale, text_stack)
    local metrics = GridLayout.metrics(kind, scale, text_stack)
    local available = tonumber(height) or 0
    if available < metrics.card_h then
        return 0
    end
    return math.max(1, math.floor((available + metrics.row_gap) / (metrics.card_h + metrics.row_gap)))
end

function GridLayout.pageWindow(item_count, visible_count, page, step_count)
    item_count = math.max(0, tonumber(item_count) or 0)
    visible_count = math.max(1, tonumber(visible_count) or 1)
    step_count = math.max(1, tonumber(step_count) or visible_count)

    local max_page = 1
    if item_count > visible_count then
        max_page = math.ceil((item_count - visible_count) / step_count) + 1
    end
    page = math.max(1, math.min(tonumber(page) or 1, max_page))

    local first = (page - 1) * step_count + 1
    local last = math.min(item_count, first + visible_count - 1)
    return {
        page = page,
        max_page = max_page,
        first = first,
        last = last,
        count = math.max(0, last - first + 1),
        visible_count = visible_count,
        step_count = step_count,
    }
end

function GridLayout.grid(kind, opts)
    opts = opts or {}
    local metrics = GridLayout.metrics(kind, opts.scale, opts.text_stack)
    local cols = opts.columns or GridLayout.columns(kind, opts.w, opts.scale, opts.text_stack)
    local rows = opts.rows or math.ceil(math.max(0, opts.item_count or 0) / cols)
    local item_count = math.max(0, tonumber(opts.item_count) or 0)
    local limit = math.min(item_count, cols * rows)
    local slots = {}

    for index = 1, limit do
        local col = (index - 1) % cols
        local row = math.floor((index - 1) / cols)
        local x = (opts.x or 0) + metrics.outer + col * (metrics.card_w + metrics.gutter)
        local y = (opts.y or 0) + row * (metrics.card_h + metrics.row_gap)
        slots[index] = cardSlot(metrics, opts, index, col + 1, row + 1, x, y)
    end

    return {
        kind = kind,
        metrics = metrics,
        columns = cols,
        rows = rows,
        slots = slots,
        visible_count = limit,
        capacity = cols * rows,
    }
end

function GridLayout.railScale(kind, width, opts)
    opts = opts or {}
    local spec = assert(SPECS[kind], "unknown bookshelf grid kind: " .. tostring(kind))
    local full_count = math.max(1, tonumber(opts.full_count) or spec.max_cols)
    local peek = math.max(0, tonumber(opts.peek) or 0)
    local left_outer = opts.left_outer == false and 0 or spec.outer
    local right_outer = opts.right_outer and spec.outer or 0
    local gutter_count = peek > 0 and full_count or math.max(0, full_count - 1)
    local target = left_outer
        + right_outer
        + (full_count + peek) * spec.card_w
        + gutter_count * spec.gutter
    if target <= 0 then
        return 1
    end
    return math.max(1, (tonumber(width) or 0) / target)
end

function GridLayout.rail(kind, opts)
    opts = opts or {}
    local scale = opts.scale
    if opts.full_count or opts.peek then
        scale = GridLayout.railScale(kind, opts.w, opts)
    end
    local metrics = GridLayout.metrics(kind, scale, opts.text_stack)
    local item_count = math.max(0, tonumber(opts.item_count) or 0)
    local slots = {}
    local x = opts.x or 0
    local y = opts.y or 0
    local origin_x = x + (opts.left_outer == false and 0 or metrics.outer)
    local right_edge = opts.right_edge or (x + (tonumber(opts.w) or 0))
    if opts.right_outer then
        right_edge = right_edge - metrics.outer
    end

    for index = 1, item_count do
        local slot_x = origin_x + (index - 1) * (metrics.card_w + metrics.gutter)
        if slot_x >= right_edge then
            break
        end
        slots[#slots + 1] = cardSlot(metrics, { scale = scale }, index, index, 1, slot_x, y)
    end

    return {
        kind = kind,
        metrics = metrics,
        scale = scale,
        slots = slots,
        visible_count = #slots,
        full_count = math.max(1, tonumber(opts.full_count) or metrics.max_cols),
        peek = math.max(0, tonumber(opts.peek) or 0),
        right_edge = right_edge,
    }
end

function GridLayout.bottomTabs(opts)
    opts = opts or {}
    local x = opts.x or 0
    local y = opts.y or 0
    local w = tonumber(opts.w) or 0
    local count = math.max(1, tonumber(opts.count) or 1)
    local scale = opts.scale
    local edge = scaleValue(16, scale)
    local content_w = math.max(0, w - edge * 2)
    local slots = {}
    local icon_size = scaleValue(24, scale)
    local top = scaleValue(10, scale)
    local bottom = scaleValue(12, scale)
    local gap = scaleValue(5, scale)
    local height = scaleValue(68, scale)
    local label_h = math.max(1, height - top - icon_size - gap - bottom)
    local label_y = y + height - bottom - label_h

    for index = 1, count do
        local slot_x = x + edge + math.floor((index - 1) * content_w / count)
        local next_x = x + edge + math.floor(index * content_w / count)
        local slot_w = math.max(1, next_x - slot_x)
        slots[index] = {
            index = index,
            x = slot_x,
            y = y,
            w = slot_w,
            h = height,
            tap = {
                x = slot_x,
                y = y,
                w = slot_w,
                h = height,
            },
            icon = {
                x = slot_x + math.floor((slot_w - icon_size) / 2),
                y = y + top,
                w = icon_size,
                h = icon_size,
            },
            label = {
                x = slot_x,
                y = label_y,
                w = slot_w,
                h = label_h,
            },
        }
    end

    return {
        x = x,
        y = y,
        w = w,
        h = height,
        edge = edge,
        top = top,
        bottom = bottom,
        icon_size = icon_size,
        icon_label_gap = gap,
        slots = slots,
    }
end

return GridLayout
