local source = debug.getinfo(1, "S").source or ""
local plugin_dir = source:match("^@(.+)/[^/]+$") or "plugins/bookshelf.koplugin"

local ReadableMeasure = dofile(plugin_dir .. "/readablemeasure.lua")

local ReadingPreset = {}

local LITERARY_SAMPLE = table.concat({
    "You will rejoice to hear that no disaster has accompanied the commencement",
    "of an enterprise which you have regarded with such evil forebodings.",
    "I arrived here yesterday, and my first task is to assure my dear sister",
    "of my welfare and increasing confidence in the success of my undertaking.",
}, " ")

local FontPacks = {
    ["source-serif-4-smtext"] = {
        id = "source-serif-4-smtext",
        display_name = "Source Serif 4 SmText",
        candidates = {
            {
                id = "source-serif-4-smtext",
                profile_font_face = "Source Serif 4 SmText",
                measurement_font = "SourceSerif4SmText-Regular.ttf",
            },
            {
                id = "noto-serif-runtime-fallback",
                profile_font_face = "Noto Serif",
                measurement_font = "NotoSerif-Regular.ttf",
            },
        },
    },
}

local Presets = {
    ["literary-latin"] = {
        id = "literary-latin",
        profile_name = "Bookshelf Literary Latin",
        -- Auto-apply is gated on the book's language: this preset's measure
        -- targets, sample text, and CSS repair are Latin assumptions and must
        -- never touch CJK books (deliberate 字取り title setting, different
        -- line-length norms, vertical writing).
        languages = { "en" },
        font_pack_id = "source-serif-4-smtext",
        target_cpl = 64,
        preferred_cpl = { min = 62, max = 68 },
        acceptable_cpl = { min = 50, max = 78 },
        margin_bounds = { min = 0, max = 140 },
        font_size_candidates = { 16, 17, 18, 19, 20, 21, 22, 23, 24 },
        line_spacing = 120,
        font_base_weight = 0,
        font_gamma = 15,
        font_kerning = 3,
        word_spacing = { 100, 85 },
        word_expansion = 0,
        embedded_css = 1,
        embedded_fonts = 1,
        sample_text = LITERARY_SAMPLE,
    },
}

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

local function list_to_set(values)
    if type(values) ~= "table" then
        return nil
    end
    local set = {}
    for key, value in pairs(values) do
        if type(key) == "string" and value == true then
            set[key] = true
        elseif type(value) == "string" then
            set[value] = true
        end
    end
    return set
end

local function get_available_faces(deps)
    if deps.available_faces then
        return list_to_set(deps.available_faces)
    end

    local ok, cre = pcall(function()
        return (deps.cre or require("document/credocument"):engineInit())
    end)
    if not ok or type(cre) ~= "table" or type(cre.getFontFaces) ~= "function" then
        return nil
    end

    local faces_ok, faces = pcall(cre.getFontFaces)
    if not faces_ok then
        return nil
    end
    return list_to_set(faces)
end

local function select_font_candidate(font_pack, deps)
    local available_faces = get_available_faces(deps)
    for _, candidate in ipairs(font_pack.candidates or {}) do
        if not available_faces or available_faces[candidate.profile_font_face] then
            return copy_table(candidate)
        end
    end
    return copy_table((font_pack.candidates or {})[1])
end

local function make_inverse_scale_by_size(scale_by_size, margin_bounds)
    margin_bounds = margin_bounds or { min = 0, max = 140 }
    return function(px)
        local best_setting = margin_bounds.min
        local best_distance
        for setting = margin_bounds.min, margin_bounds.max do
            local distance = math.abs(scale_by_size(setting) - px)
            if best_distance == nil or distance < best_distance then
                best_setting = setting
                best_distance = distance
            end
        end
        return best_setting
    end
end

local function get_screen(deps)
    if deps.Screen then
        return deps.Screen
    end
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.screen then
        return Device.screen
    end
end

function ReadingPreset.makeKOReaderMeasureText(deps)
    deps = deps or {}
    local Font = deps.Font or require("ui/font")
    local RenderText = deps.RenderText or require("ui/rendertext")

    return function(text, measurement_font, body_size)
        local face = Font:getFace(measurement_font, body_size)
        assert(face, "font unavailable for measurement: " .. tostring(measurement_font))

        local measured = RenderText:sizeUtf8Text(0, false, face, text, true, false)
        local width = measured and (measured.x or measured.w or measured.width)
        assert(width, "KOReader text measurement did not return a width")
        return width
    end
end

function ReadingPreset.getPreset(preset_id)
    local preset = Presets[preset_id]
    assert(preset, "unknown reading preset: " .. tostring(preset_id))
    return copy_table(preset)
end

function ReadingPreset.getFontPack(font_pack_id)
    local font_pack = FontPacks[font_pack_id]
    assert(font_pack, "unknown font pack: " .. tostring(font_pack_id))
    return copy_table(font_pack)
end

function ReadingPreset.deriveProfile(opts)
    opts = opts or {}
    local deps = opts.deps or opts
    local preset = opts.preset or ReadingPreset.getPreset(opts.reading_preset_id or opts.preset_id or "literary-latin")
    local font_pack = opts.font_pack or ReadingPreset.getFontPack(preset.font_pack_id)
    local font_candidate = opts.font_candidate or select_font_candidate(font_pack, deps)
    local screen = get_screen(deps)
    local viewport_width_px = opts.viewport_width_px
        or (screen and type(screen.getWidth) == "function" and screen:getWidth())

    assert(viewport_width_px, "viewport_width_px is required when KOReader Screen is unavailable")

    local scale_by_size = opts.scale_by_size
        or (screen and function(value) return screen:scaleBySize(value) end)
        or function(value) return value end
    local inverse_scale_by_size = opts.inverse_scale_by_size
        or make_inverse_scale_by_size(scale_by_size, preset.margin_bounds)

    local result = ReadableMeasure.translateToKOReaderProfile({
        reading_preset_id = preset.id,
        profile_name = preset.profile_name,
        font_candidate = font_candidate.id,
        font_face = font_candidate.measurement_font,
        profile_font_face = font_candidate.profile_font_face,
        viewport_width_px = viewport_width_px,
        target_cpl = preset.target_cpl,
        preferred_cpl = preset.preferred_cpl,
        acceptable_cpl = preset.acceptable_cpl,
        margin_bounds = preset.margin_bounds,
        font_size_candidates = preset.font_size_candidates,
        sample_text = opts.sample_text or preset.sample_text,
        character_count = opts.character_count,
        measure_text = opts.measure_text or ReadingPreset.makeKOReaderMeasureText(deps),
        scale_by_size = scale_by_size,
        inverse_scale_by_size = inverse_scale_by_size,
        line_spacing = preset.line_spacing,
        font_base_weight = preset.font_base_weight,
        font_gamma = preset.font_gamma,
        font_kerning = preset.font_kerning,
        word_spacing = preset.word_spacing,
        word_expansion = preset.word_expansion,
        embedded_css = preset.embedded_css,
        embedded_fonts = preset.embedded_fonts,
    })

    result.font_pack_id = font_pack.id
    result.font_candidate = font_candidate
    result.readable_measure_snapshot = {
        rule_id = "latin-literary-cpl",
        reading_preset_id = preset.id,
        font_pack_id = font_pack.id,
        font_candidate_id = font_candidate.id,
        profile_font_face = font_candidate.profile_font_face,
        measurement_font = font_candidate.measurement_font,
        target_cpl = preset.target_cpl,
        preferred_cpl = copy_table(preset.preferred_cpl),
        acceptable_cpl = copy_table(preset.acceptable_cpl),
        candidate = copy_table(result.candidate),
    }

    return result
end

function ReadingPreset.appliesToLanguage(preset, language)
    local languages = type(preset) == "table" and preset.languages
    if type(languages) ~= "table" then
        return false
    end
    if type(language) ~= "string" or language == "" then
        return false
    end
    language = language:lower()
    for _, candidate in ipairs(languages) do
        local prefix = tostring(candidate):lower()
        if language == prefix or language:sub(1, #prefix + 1) == prefix .. "-" then
            return true
        end
    end
    return false
end

-- Project Gutenberg's template CSS letterspaces headings (0.12em), inflates
-- h1 to 300%, and paints background slabs that render as gray smudges on
-- e-ink. Repair that noise for PG-identified books only — carefully typeset
-- books are never touched, and the result stays a per-book reversible tweak.
function ReadingPreset.publisherRepairCss(doc_props)
    local identifiers = type(doc_props) == "table" and tostring(doc_props.identifiers or "") or ""
    if not identifiers:lower():find("gutenberg%.org") then
        return nil
    end
    return table.concat({
        "h1, h2, h3, h4, h5, h6 {",
        "    letter-spacing: normal !important;",
        "    word-spacing: normal !important;",
        "}",
        "h1 {",
        "    font-size: 200% !important;",
        "}",
        "body, div, p, blockquote, pre {",
        "    background-color: transparent !important;",
        "}",
    }, "\n")
end

ReadingPreset.presets = Presets
ReadingPreset.font_packs = FontPacks

return ReadingPreset
