-- Captures a short passage from the reader's current page so the library
-- home can show where they left off without ever opening the document.
-- capture() runs in the reader host (document open, position live) on
-- SaveSettings; the result is cached in the book's own sidecar settings.

local ResumeSnippet = {
    max_chars = 240,
    snippet_setting = "bookshelf_resume_snippet",
    chapter_setting = "bookshelf_resume_chapter",
}

local function utf8Truncate(text, max_chars)
    local length = 0
    local index = 1
    local byte_count = #text
    while index <= byte_count do
        if length >= max_chars then
            return text:sub(1, index - 1), true
        end
        local byte = text:byte(index)
        if byte < 0x80 then index = index + 1
        elseif byte < 0xE0 then index = index + 2
        elseif byte < 0xF0 then index = index + 3
        else index = index + 4
        end
        length = length + 1
    end
    return text, false
end

function ResumeSnippet.normalize(raw, max_chars)
    if type(raw) ~= "string" then
        return nil
    end
    local text = raw:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return nil
    end

    local clamped, truncated = utf8Truncate(text, max_chars or ResumeSnippet.max_chars)
    if truncated then
        local at_word = clamped:match("^(.-)%s%S*$")
        if at_word and #at_word >= math.floor(#clamped / 2) then
            clamped = at_word
        end
        clamped = clamped .. "…"
    end
    return clamped
end

local function pageTextFromCre(document, deps)
    if type(document.getTextFromPositions) ~= "function" then
        return nil
    end
    local screen = deps.screen
    if not screen then
        local ok, Device = pcall(require, "device")
        screen = ok and Device and Device.screen
    end
    if not screen then
        return nil
    end

    local ok, selection = pcall(document.getTextFromPositions, document,
        { x = 0, y = 0 },
        { x = screen:getWidth(), y = screen:getHeight() },
        true) -- do_not_draw_selection
    if type(document.clearSelection) == "function" then
        pcall(document.clearSelection, document)
    end
    if ok and type(selection) == "table" and type(selection.text) == "string" then
        return selection.text
    end
end

local function pageTextFromBoxes(document, ui)
    if type(document.getPageText) ~= "function" or type(ui.getCurrentPage) ~= "function" then
        return nil
    end
    local page_ok, page = pcall(ui.getCurrentPage, ui)
    if not page_ok or not page then
        return nil
    end
    local ok, boxes = pcall(document.getPageText, document, page)
    if not ok or type(boxes) ~= "table" then
        return nil
    end

    local words = {}
    for _, line in ipairs(boxes) do
        if type(line) == "table" then
            for _, word in ipairs(line) do
                if type(word) == "table" and type(word.word) == "string" then
                    words[#words + 1] = word.word
                end
            end
        end
    end
    return table.concat(words, " ")
end

local function chapterTitle(ui)
    if not ui.toc or type(ui.toc.getTocTitleByPage) ~= "function"
        or type(ui.getCurrentPage) ~= "function" then
        return nil
    end
    local page_ok, page = pcall(ui.getCurrentPage, ui)
    if not page_ok or not page then
        return nil
    end
    local ok, title = pcall(ui.toc.getTocTitleByPage, ui.toc, page)
    if ok and type(title) == "string" and title ~= "" then
        return title
    end
end

function ResumeSnippet.capture(ui, deps)
    deps = deps or {}
    local document = ui and ui.document
    local doc_settings = ui and ui.doc_settings
    if not document or not doc_settings or type(doc_settings.saveSetting) ~= "function" then
        return false
    end

    local raw = pageTextFromCre(document, deps)
    if raw == nil or raw == "" then
        raw = pageTextFromBoxes(document, ui)
    end

    local snippet = ResumeSnippet.normalize(raw, ResumeSnippet.max_chars)
    if not snippet then
        return false
    end

    doc_settings:saveSetting(ResumeSnippet.snippet_setting, snippet)
    doc_settings:saveSetting(ResumeSnippet.chapter_setting, chapterTitle(ui))
    return true
end

return ResumeSnippet
