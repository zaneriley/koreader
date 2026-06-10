local DownloadedBookProvider = {}

local EMPTY = {}
local DEFAULT_SORT = "title"

local function readSetting(name)
    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        return G_reader_settings:readSetting(name)
    end
end

local function asString(value)
    if value == nil then
        return nil
    elseif type(value) == "boolean" then
        return nil
    end
    value = tostring(value)
    value = value:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if value == "" then
        return nil
    end
    return value
end

local function sortString(value)
    return (asString(value) or ""):lower()
end

local function splitFilePathName(file)
    if file == nil or file == "" then
        return "", ""
    elseif not file:find("/") then
        return "", file
    end
    return file:match("(.*/)(.*)")
end

local function splitFileNameSuffix(file)
    if file == nil or file == "" then
        return "", ""
    elseif not file:find("%.") then
        return file, ""
    end
    return file:match("(.*)%.(.*)")
end

local function filenameFromPath(file)
    local _, filename = splitFilePathName(file)
    return asString(filename) or asString(file) or ""
end

local function filenameWithoutSuffix(file)
    local filename = filenameFromPath(file)
    local basename = splitFileNameSuffix(filename)
    return asString(basename) or filename
end

local function getFile(row)
    if type(row) == "string" then
        return row
    elseif type(row) == "table" then
        return row.file or row.path or row.filepath
    end
end

local function getRowsInDeterministicOrder(rows)
    if type(rows) ~= "table" then
        return {}
    end

    if #rows > 0 then
        return rows
    end

    local keys = {}
    for key in pairs(rows) do
        table.insert(keys, key)
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    local ordered = {}
    for _, key in ipairs(keys) do
        table.insert(ordered, rows[key])
    end
    return ordered
end

local function readBookInfo(file, row, opts)
    if type(row) == "table" and type(row.book_info) == "table" then
        return row.book_info
    elseif type(opts.get_book_info) == "function" then
        return opts.get_book_info(file, row) or EMPTY
    elseif opts.no_book_info then
        return EMPTY
    end

    local BookList = opts.BookList or require("ui/widget/booklist")
    return BookList.getBookInfo(file) or EMPTY
end

local function readDocProps(file, row, opts)
    if type(row) == "table" then
        if type(row.doc_props) == "table" then
            return row.doc_props
        elseif type(row.book_props) == "table" then
            return row.book_props
        end
    end

    if type(opts.get_doc_props) == "function" then
        return opts.get_doc_props(file, row) or EMPTY
    elseif opts.ui and opts.ui.bookinfo and type(opts.ui.bookinfo.getDocProps) == "function" then
        return opts.ui.bookinfo:getDocProps(file, nil, true) or EMPTY
    elseif opts.bookinfo and type(opts.bookinfo.getDocProps) == "function" then
        return opts.bookinfo:getDocProps(file) or EMPTY
    end

    return EMPTY
end

local function readAttributes(file, row, opts)
    if type(row) == "table" then
        if type(row.attributes) == "table" then
            return row.attributes
        elseif type(row.attr) == "table" then
            return row.attr
        end
    end

    if type(opts.get_attributes) == "function" then
        return opts.get_attributes(file, row) or EMPTY
    elseif opts.no_attributes then
        return EMPTY
    end

    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(file) or EMPTY
end

local function firstPresent(...)
    for i = 1, select("#", ...) do
        local value = asString(select(i, ...))
        if value then
            return value
        end
    end
end

-- KOReader stores multiple authors newline-separated; join them before
-- asString collapses the newline into a plain space.
local function joinAuthorLines(value)
    if type(value) ~= "string" then
        return value
    end
    return (value:gsub("%s*\n%s*", ", "))
end

function DownloadedBookProvider.getStableId(file)
    return "downloaded:" .. tostring(file or "")
end

function DownloadedBookProvider.recordFromRow(row, opts)
    opts = opts or {}
    local file = getFile(row)
    if not asString(file) then
        return nil
    end

    local doc_props = readDocProps(file, row, opts)
    local book_info = readBookInfo(file, row, opts)
    local attributes = readAttributes(file, row, opts)
    local filename = filenameFromPath(file)
    local display_title = firstPresent(
        doc_props.display_title,
        doc_props.title,
        type(row) == "table" and (row.title or row.text),
        filenameWithoutSuffix(file),
        file
    )
    local authors = firstPresent(
        joinAuthorLines(doc_props.authors),
        type(row) == "table" and joinAuthorLines(row.authors))
    local series = firstPresent(doc_props.series)
    local exists
    if type(row) == "table" and row.select_enabled ~= nil then
        exists = row.select_enabled and true or false
    elseif attributes.mode ~= nil then
        exists = attributes.mode == "file"
    end

    local record = {
        id = DownloadedBookProvider.getStableId(file),
        type = "downloaded_book",
        file = file,
        path = file,
        filename = filename,
        title = display_title,
        display_title = display_title,
        text = display_title,
        authors = authors,
        series = series,
        series_index = doc_props.series_index,
        language = firstPresent(doc_props.language),
        keywords = firstPresent(doc_props.keywords),
        description = firstPresent(doc_props.description),
        pages = doc_props.pages or book_info.pages,
        status = book_info.been_opened == false and "new" or (book_info.status or "new"),
        percent_finished = book_info.percent_finished or 0,
        last_read = type(row) == "table" and row.time or attributes.access,
        modified = attributes.modification,
        size = attributes.size,
        file_exists = exists,
        select_enabled = exists ~= false,
    }

    record.subtitle = authors or series
    record.sort_title = sortString(record.display_title)
    record.sort_authors = sortString(record.authors)
    record.sort_series = sortString(record.series)
    record.sort_path = sortString(record.path)

    return record
end

local sorters = {
    title = function(a, b)
        if a.sort_title ~= b.sort_title then
            return a.sort_title < b.sort_title
        elseif a.sort_authors ~= b.sort_authors then
            return a.sort_authors < b.sort_authors
        elseif a.sort_series ~= b.sort_series then
            return a.sort_series < b.sort_series
        end
        return a.id < b.id
    end,
    recent = function(a, b)
        local a_time = a.last_read or 0
        local b_time = b.last_read or 0
        if a_time ~= b_time then
            return a_time > b_time
        elseif a.sort_title ~= b.sort_title then
            return a.sort_title < b.sort_title
        end
        return a.id < b.id
    end,
    path = function(a, b)
        if a.sort_path ~= b.sort_path then
            return a.sort_path < b.sort_path
        end
        return a.id < b.id
    end,
}

function DownloadedBookProvider.sortRecords(records, sort_key)
    table.sort(records, sorters[sort_key or DEFAULT_SORT] or sorters[DEFAULT_SORT])
    return records
end

function DownloadedBookProvider.recordsFromRows(rows, opts)
    opts = opts or {}
    local records = {}
    local seen = {}

    for _, row in ipairs(getRowsInDeterministicOrder(rows)) do
        local record = DownloadedBookProvider.recordFromRow(row, opts)
        if record and not seen[record.id] then
            seen[record.id] = true
            table.insert(records, record)
        end
    end

    return DownloadedBookProvider.sortRecords(records, opts.sort)
end

function DownloadedBookProvider.getDownloadDir(opts)
    opts = opts or {}
    return asString(opts.download_dir)
        or asString(readSetting("download_dir"))
        or asString(readSetting("lastdir"))
end

function DownloadedBookProvider.rowsFromDownloadDir(opts)
    opts = opts or {}
    if type(opts.list_download_dir) == "function" then
        return opts.list_download_dir(DownloadedBookProvider.getDownloadDir(opts), opts) or {}
    end

    local download_dir = DownloadedBookProvider.getDownloadDir(opts)
    if not download_dir then
        return {}
    end

    local lfs = opts.lfs or require("libs/libkoreader-lfs")
    local DocumentRegistry = opts.DocumentRegistry or require("document/documentregistry")
    local rows = {}
    local ok, iterator, dir_obj = pcall(lfs.dir, download_dir)
    if not ok or type(iterator) ~= "function" then
        return rows
    end

    for entry in iterator, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local file = (download_dir ~= "/" and download_dir or "") .. "/" .. entry
            local attr_ok, attributes = pcall(lfs.attributes, file)
            attributes = attr_ok and attributes or nil
            if attributes and attributes.mode == "file" and DocumentRegistry:hasProvider(file) then
                table.insert(rows, {
                    file = file,
                    attributes = attributes,
                })
            end
        end
    end

    table.sort(rows, function(a, b)
        local a_modified = a.attributes and a.attributes.modification or 0
        local b_modified = b.attributes and b.attributes.modification or 0
        if a_modified ~= b_modified then
            return a_modified > b_modified
        end
        return a.file < b.file
    end)
    return rows
end

function DownloadedBookProvider.getDownloadedBooks(opts)
    opts = opts or {}
    if opts.rows then
        return DownloadedBookProvider.recordsFromRows(opts.rows, opts)
    end

    opts.sort = opts.sort or "recent"
    return DownloadedBookProvider.recordsFromRows(DownloadedBookProvider.rowsFromDownloadDir(opts), opts)
end

function DownloadedBookProvider.getContinue(opts)
    opts = opts or {}
    local ReadHistory = opts.ReadHistory or require("readhistory")
    if ReadHistory.reload then
        ReadHistory:reload()
    end
    return DownloadedBookProvider.recordFromRow((ReadHistory.hist or {})[1], opts)
end

return DownloadedBookProvider
