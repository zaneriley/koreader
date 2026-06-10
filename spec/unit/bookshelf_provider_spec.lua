describe("Bookshelf downloaded-book provider", function()
    local Provider

    setup(function()
        require("commonrequire")
        Provider = dofile("plugins/bookshelf.koplugin/provider.lua")
    end)

    local function no_probe_opts()
        return {
            get_doc_props = function()
                error("document metadata probe should not be needed")
            end,
            get_book_info = function()
                error("book info probe should not be needed")
            end,
            get_attributes = function()
                error("file attributes probe should not be needed")
            end,
        }
    end

    local function synthetic_rows(size)
        local rows = {}
        for i = size, 1, -1 do
            table.insert(rows, {
                file = string.format("/downloads/book-%04d.epub", i),
                doc_props = {
                    title = string.format("Book %04d", i),
                    authors = string.format("Author %02d", i % 17),
                },
                book_info = {
                    been_opened = i % 2 == 0,
                    status = i % 2 == 0 and "reading" or nil,
                    percent_finished = (i % 100) / 100,
                },
                attributes = {
                    mode = "file",
                    size = i * 13,
                    modification = 100000 + i,
                },
                time = 200000 + i,
            })
        end
        return rows
    end

    it("keeps stable ids independent of metadata and input order", function()
        local opts = no_probe_opts()
        local first = Provider.recordFromRow({
            file = "/downloads/same.epub",
            doc_props = { title = "Original title" },
            book_info = { been_opened = true, status = "reading" },
            attributes = { mode = "file" },
        }, opts)
        local second = Provider.recordFromRow({
            file = "/downloads/same.epub",
            doc_props = { title = "Changed title", authors = "Someone" },
            book_info = { been_opened = true, status = "complete" },
            attributes = { mode = "file" },
        }, opts)

        assert.equals("downloaded:/downloads/same.epub", first.id)
        assert.equals(first.id, second.id)
    end)

    it("returns displayable fallback records when metadata is missing", function()
        local record = Provider.recordFromRow({
            file = "/downloads/Missing Metadata.pdf",
            book_info = { been_opened = false },
            attributes = { mode = "file", size = 42 },
        }, {
            get_doc_props = function()
                return {}
            end,
        })

        assert.equals("Missing Metadata", record.display_title)
        assert.equals(record.display_title, record.text)
        assert.equals("new", record.status)
        assert.equals(42, record.size)
        assert.is_nil(record.subtitle)
        assert.is_true(record.select_enabled)
    end)

    it("uses the OPDS fallback download folder when download_dir is not configured", function()
        local old_settings = _G.G_reader_settings
        _G.G_reader_settings = {
            readSetting = function(_, name)
                if name == "lastdir" then
                    return "/file-browser-downloads"
                end
            end,
        }

        local download_dir = Provider.getDownloadDir({})
        _G.G_reader_settings = old_settings

        assert.equals("/file-browser-downloads", download_dir)
    end)

    it("returns an empty shelf when the download directory is missing", function()
        local rows = Provider.rowsFromDownloadDir({
            download_dir = "/missing",
            lfs = {
                dir = function()
                    error("missing directory")
                end,
                attributes = function()
                    error("attributes should not be read after dir fails")
                end,
            },
            DocumentRegistry = {
                hasProvider = function()
                    error("providers should not be probed after dir fails")
                end,
            },
        })

        assert.are.same({}, rows)
    end)

    it("sorts downloaded records deterministically", function()
        local rows = {
            {
                file = "/downloads/zeta.epub",
                doc_props = { title = "Same", authors = "B" },
                book_info = { been_opened = true, status = "reading" },
                attributes = { mode = "file" },
            },
            {
                file = "/downloads/alpha.epub",
                doc_props = { title = "same", authors = "A" },
                book_info = { been_opened = true, status = "reading" },
                attributes = { mode = "file" },
            },
            {
                file = "/downloads/beta.epub",
                doc_props = { title = "Another" },
                book_info = { been_opened = false },
                attributes = { mode = "file" },
            },
            {
                file = "/downloads/omega.epub",
                doc_props = { title = "Same", authors = "B" },
                book_info = { been_opened = true, status = "reading" },
                attributes = { mode = "file" },
            },
        }

        local records = Provider.recordsFromRows(rows, no_probe_opts())

        assert.are.same({
            "downloaded:/downloads/beta.epub",
            "downloaded:/downloads/alpha.epub",
            "downloaded:/downloads/omega.epub",
            "downloaded:/downloads/zeta.epub",
        }, {
            records[1].id,
            records[2].id,
            records[3].id,
            records[4].id,
        })
    end)

    it("uses cached row metadata without probing expensive providers", function()
        local records = Provider.recordsFromRows({
            {
                file = "/downloads/cached.epub",
                doc_props = { title = "Cached Row", authors = "Local" },
                book_info = { been_opened = true, status = "reading" },
                attributes = { mode = "file" },
            },
        }, no_probe_opts())

        assert.equals(1, #records)
        assert.equals("Cached Row", records[1].display_title)
        assert.equals("Local", records[1].authors)
    end)

    it("joins newline-separated authors with a comma", function()
        local records = Provider.recordsFromRows({
            {
                file = "/downloads/grimms.epub",
                doc_props = { title = "Grimms' Fairy Tales", authors = "Jacob Grimm\nWilhelm Grimm" },
                book_info = { been_opened = true, status = "reading" },
                attributes = { mode = "file" },
            },
        }, no_probe_opts())

        assert.equals("Jacob Grimm, Wilhelm Grimm", records[1].authors)
    end)

    it("enriches the continue record with the cached resume snippet", function()
        local record = Provider.getContinue({
            ReadHistory = {
                reload = function() end,
                hist = {
                    {
                        file = "/downloads/grimms.epub",
                        doc_props = { title = "Grimms' Fairy Tales", authors = "Jacob Grimm" },
                        book_info = { been_opened = true, status = "reading", percent_finished = 0.03 },
                        attributes = { mode = "file" },
                    },
                },
            },
            read_doc_setting = function(file, key)
                assert.equals("/downloads/grimms.epub", file)
                if key == "bookshelf_resume_snippet" then
                    return "In the olden days, when wishing still helped…"
                elseif key == "bookshelf_resume_chapter" then
                    return "The Frog-King"
                end
            end,
        })

        assert.equals("In the olden days, when wishing still helped…", record.resume_snippet)
        assert.equals("The Frog-King", record.resume_chapter)
    end)

    it("handles large synthetic downloaded shelves", function()
        for _, size in ipairs({ 0, 1, 12, 100, 1000, 5000 }) do
            local records = Provider.recordsFromRows(synthetic_rows(size), no_probe_opts())

            assert.equals(size, #records)
            if size > 0 then
                assert.equals("downloaded:/downloads/book-0001.epub", records[1].id)
                assert.equals(string.format("downloaded:/downloads/book-%04d.epub", size), records[#records].id)
            end
        end
    end)

    it("builds downloaded records from the configured download directory", function()
        local records = Provider.getDownloadedBooks({
            sort = "recent",
            get_doc_props = function()
                return {}
            end,
            get_book_info = function()
                return { been_opened = false }
            end,
            list_download_dir = function(download_dir)
                assert.equals("/downloads", download_dir)
                return {
                    {
                        file = "/downloads/older.epub",
                        attributes = { mode = "file", modification = 10 },
                    },
                    {
                        file = "/downloads/newer.epub",
                        attributes = { mode = "file", modification = 20 },
                    },
                }
            end,
            download_dir = "/downloads",
        })

        assert.equals(2, #records)
        assert.equals("downloaded:/downloads/newer.epub", records[1].id)
        assert.equals("downloaded:/downloads/older.epub", records[2].id)
    end)

    it("keeps continue separate from the downloaded shelf", function()
        local record = Provider.getContinue({
            ReadHistory = {
                hist = {
                    {
                        file = "/history/current.epub",
                        text = "Current Book",
                        book_info = { been_opened = true, status = "reading" },
                        attributes = { mode = "file" },
                    },
                },
            },
            get_doc_props = function()
                return {}
            end,
        })

        assert.equals("downloaded:/history/current.epub", record.id)
        assert.equals("Current Book", record.display_title)
    end)
end)
