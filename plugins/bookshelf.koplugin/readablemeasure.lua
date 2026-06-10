local ReadableMeasure = {}

local DEFAULT_PREFERRED_CPL = { min = 60, max = 64 }
local DEFAULT_ACCEPTABLE_CPL = { min = 55, max = 70 }
local DEFAULT_PROFILE_ORDER = {
    "set_font", "font_size", "font_base_weight", "font_gamma",
    "font_kerning", "h_page_margins", "line_spacing",
    "word_spacing", "word_expansion", "embedded_css", "embedded_fonts",
}

local function clamp(value, min_value, max_value)
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function round(value)
    return math.floor(value + 0.5)
end

local function copy_array(values)
    local copy = {}
    for index, value in ipairs(values or {}) do
        copy[index] = value
    end
    return copy
end

local function copy_table(values)
    local copy = {}
    for key, value in pairs(values or {}) do
        if type(value) == "table" then
            copy[key] = copy_table(value)
        else
            copy[key] = value
        end
    end
    return copy
end

local function utf8_length(text)
    text = tostring(text or "")
    local length = 0
    local index = 1
    local text_length = string.len(text)

    while index <= text_length do
        local byte = string.byte(text, index)
        if not byte then break
        elseif byte < 0x80 then index = index + 1
        elseif byte < 0xE0 then index = index + 2
        elseif byte < 0xF0 then index = index + 3
        else index = index + 4
        end
        length = length + 1
    end

    return length
end

local function assert_number(name, value)
    local number = tonumber(value)
    assert(number, name .. " must be a number")
    return number
end

local function normalize_range(range, fallback)
    range = range or fallback
    local normalized = {
        min = assert_number("range.min", range.min),
        max = assert_number("range.max", range.max),
    }
    assert(normalized.min <= normalized.max, "range.min must be <= range.max")
    return normalized
end

local function range_status(value, preferred, acceptable)
    if value >= preferred.min and value <= preferred.max then
        return "preferred"
    end
    if value >= acceptable.min and value <= acceptable.max then
        return "acceptable"
    end
    return "fail"
end

local function target_distance(value, target)
    return math.abs(value - target)
end

function ReadableMeasure.utf8Length(text)
    return utf8_length(text)
end

function ReadableMeasure.averageAdvance(opts)
    opts = opts or {}
    local sample_text = assert(opts.sample_text, "sample_text is required")
    local char_count = opts.character_count or utf8_length(sample_text)
    assert(char_count > 0, "sample_text must contain at least one character")

    local width
    if opts.measured_width_px then
        width = opts.measured_width_px
    else
        assert(type(opts.measure_text) == "function", "measure_text is required")
        width = opts.measure_text(sample_text, opts.body_typeface, opts.body_size)
    end
    width = assert_number("measured_width_px", width)
    assert(width > 0, "measured_width_px must be positive")

    return width / char_count, char_count, width
end

local function build_profile(opts, candidate)
    local profile = copy_table(opts.profile or {})
    profile.settings = profile.settings or {}
    profile.settings.name = profile.settings.name or opts.profile_name or opts.reading_preset_id
    profile.settings.order = copy_array(profile.settings.order or DEFAULT_PROFILE_ORDER)
    profile.set_font = opts.profile_font_face or opts.font_face
    profile.font_size = candidate.font_size
    profile.h_page_margins = { candidate.margin_setting, candidate.margin_setting }
    profile.line_spacing = opts.line_spacing
    profile.font_base_weight = opts.font_base_weight
    profile.font_gamma = opts.font_gamma
    profile.font_kerning = opts.font_kerning
    profile.word_spacing = opts.word_spacing
    profile.word_expansion = opts.word_expansion
    profile.embedded_css = opts.embedded_css
    profile.embedded_fonts = opts.embedded_fonts
    return profile
end

function ReadableMeasure.translateToKOReaderProfile(opts)
    opts = opts or {}

    local viewport_width_px = assert_number("viewport_width_px", opts.viewport_width_px)
    local dpi = assert_number("dpi", opts.dpi or 226)

    local target_cpl = assert_number("target_cpl", opts.target_cpl or 62)
    local preferred_cpl = normalize_range(opts.preferred_cpl, DEFAULT_PREFERRED_CPL)
    local acceptable_cpl = normalize_range(opts.acceptable_cpl, DEFAULT_ACCEPTABLE_CPL)

    assert(opts.font_face, "font_face is required")

    local scale = opts.scale or 1
    local scale_by_size = opts.scale_by_size or function(value) return value * scale end
    local inverse_scale_by_size = opts.inverse_scale_by_size or function(value) return value / scale end

    local test_logical_size = 22
    local test_engine_size_px = scale_by_size(test_logical_size)
    local avg_char_advance_px = ReadableMeasure.averageAdvance({
        sample_text = opts.sample_text,
        character_count = opts.character_count,
        body_typeface = opts.font_face,
        body_size = test_logical_size,
        measure_text = opts.measure_text,
        measured_width_px = opts.measured_width_px,
    })
    local a = avg_char_advance_px / test_engine_size_px

    local best_candidate = nil
    local best_score = math.huge
    local columns = 1
    local gutter_px = 0

    local min_cpl = acceptable_cpl.min
    local max_cpl = acceptable_cpl.max

    local min_margin_pt = opts.min_margin_pt or 12
    local max_margin_pt = opts.max_margin_pt or 200
    local min_margin_px = min_margin_pt * dpi / 72
    local max_margin_px = max_margin_pt * dpi / 72
    local preferred_margin_pt = opts.preferred_margin_pt or 36
    local preferred_margin_px = preferred_margin_pt * dpi / 72
    local margin_span = max_margin_px - min_margin_px
    if margin_span <= 0 then margin_span = 1 end

    local candidates = opts.font_size_candidates or { 16, 17, 18, 19, 20, 21, 22, 23, 24 }
    local target_logical_font_size = opts.target_logical_font_size or 22
    local font_size_span = math.abs(candidates[1] - candidates[table.maxn(candidates)])
    if font_size_span == 0 then font_size_span = 1 end

    local cpl_span = max_cpl - min_cpl
    if cpl_span <= 0 then cpl_span = 1 end

    local margin_bounds = opts.margin_bounds or { min = 0, max = 140 }

    local logger = require("logger")
    logger.info("Bookshelf debugging constraint solver start. a=", a, "viewport_width_px=", viewport_width_px)

    -- Tier 1: Strict valid layout
    for _, logical_size in ipairs(candidates) do
        local engine_size_px = scale_by_size(logical_size)
        local advance_px = engine_size_px * a

        local cpl_margin_min = (viewport_width_px - gutter_px * (columns - 1) - columns * max_cpl * advance_px) / 2
        local cpl_margin_max = (viewport_width_px - gutter_px * (columns - 1) - columns * min_cpl * advance_px) / 2

        local valid_margin_min = math.max(cpl_margin_min, min_margin_px)
        local valid_margin_max = math.min(cpl_margin_max, max_margin_px)

        local min_ui_margin_px = scale_by_size(margin_bounds.min)
        local max_ui_margin_px = scale_by_size(margin_bounds.max)
        valid_margin_min = math.max(valid_margin_min, min_ui_margin_px)
        valid_margin_max = math.min(valid_margin_max, max_ui_margin_px)

        if valid_margin_min <= valid_margin_max then
            local chosen_margin_px = clamp(preferred_margin_px, valid_margin_min, valid_margin_max)
            local chosen_margin_setting = clamp(round(inverse_scale_by_size(chosen_margin_px)), margin_bounds.min, margin_bounds.max)
            local rendered_margin_px = scale_by_size(chosen_margin_setting)

            local content_width_px = math.max(0, viewport_width_px - 2 * rendered_margin_px - gutter_px * (columns - 1))
            local actual_cpl = (content_width_px / columns) / advance_px

            local font_weight = opts.font_weight or 3.0
            local margin_weight = opts.margin_weight or 2.0
            local cpl_weight = opts.cpl_weight or 1.0

            local font_penalty = math.abs(logical_size - target_logical_font_size) / font_size_span
            local margin_penalty = math.abs(rendered_margin_px - preferred_margin_px) / margin_span
            local cpl_penalty = math.abs(actual_cpl - target_cpl) / cpl_span

            local score = (font_weight * font_penalty) + (margin_weight * margin_penalty) + (cpl_weight * cpl_penalty)

            logger.info(string.format("Bookshelf debugging candidate %d: sz_px=%.1f, m_px=%.1f, cpl=%.1f, score=%.3f", logical_size, engine_size_px, rendered_margin_px, actual_cpl, score))

            if score < best_score then
                best_score = score
                best_candidate = {
                    font_size_logical = logical_size,
                    font_size_px = engine_size_px,
                    font_size = logical_size,
                    target_cpl = target_cpl,
                    target_width_px = actual_cpl * advance_px,
                    requested_margin_px = chosen_margin_px,
                    requested_margin_setting = chosen_margin_setting,
                    margin_setting = chosen_margin_setting,
                    rendered_margin_px = rendered_margin_px,
                    avg_char_advance_px = advance_px,
                    content_width_px = content_width_px,
                    estimated_cpl = actual_cpl,
                    measure_status = range_status(actual_cpl, preferred_cpl, acceptable_cpl),
                    distance_to_target = target_distance(actual_cpl, target_cpl),
                }
            end
        else
            logger.info("Bookshelf debugging candidate", logical_size, "rejected: margin range does not overlap valid bounds")
        end
    end

    local result = {
        reading_preset_id = opts.reading_preset_id,
        font_candidate = opts.font_candidate,
        target_cpl = target_cpl,
        preferred_cpl = preferred_cpl,
        acceptable_cpl = acceptable_cpl,
        candidate = best_candidate,
    }

    if not best_candidate then
        result.result = "fail"
        result.failure_owner = "Reading Preset tuning"
    else
        result.profile = build_profile(opts, best_candidate)

        local css_lines = {
            "/* Bookshelf Ephemeral Typography Tweak */",
            "p, li, blockquote {",
            "    font-family: inherit !important;",
            "}",
        }
        result.css_tweak = table.concat(css_lines, "\n")


        if best_candidate.measure_status == "fail" then
            result.result = "needs-followup"
            result.failure_owner = nil
        elseif best_candidate.measure_status == "acceptable" then
            result.result = "needs-followup"
            result.failure_owner = nil
        else
            result.result = "pass"
            result.failure_owner = nil
        end
    end

    return result
end

return ReadableMeasure
