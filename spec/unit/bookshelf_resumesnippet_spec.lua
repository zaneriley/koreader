describe("Bookshelf resume snippet", function()
    local ResumeSnippet

    setup(function()
        require("commonrequire")
        ResumeSnippet = dofile("plugins/bookshelf.koplugin/resumesnippet.lua")
    end)

    it("collapses whitespace and trims the captured text", function()
        assert.equals("In the olden days", ResumeSnippet.normalize("  In the \n  olden\tdays  "))
    end)

    it("returns nil for empty or non-string input", function()
        assert.is_nil(ResumeSnippet.normalize(nil))
        assert.is_nil(ResumeSnippet.normalize(""))
        assert.is_nil(ResumeSnippet.normalize("   \n  "))
        assert.is_nil(ResumeSnippet.normalize(42))
    end)

    it("clamps long text at a word boundary with an ellipsis", function()
        local snippet = ResumeSnippet.normalize(string.rep("word ", 100), 50)
        assert.is_truthy(snippet:match("…$"))
        assert.is_truthy(snippet:match("word…$"))
        assert.is_true(#snippet <= 50 + #"…")
    end)

    it("never splits a multibyte character when clamping", function()
        local snippet = ResumeSnippet.normalize(string.rep("あ", 100), 10)
        -- 10 three-byte characters plus the ellipsis, no partial sequence
        assert.equals(10 * 3 + #"…", #snippet)
    end)

    it("captures the visible page into doc settings via the cre selection api", function()
        local saved = {}
        local cleared = false
        local ui = {
            document = {
                getTextFromPositions = function()
                    return { text = "  In the   olden days, when wishing still helped  " }
                end,
                clearSelection = function()
                    cleared = true
                end,
            },
            doc_settings = {
                saveSetting = function(_, key, value)
                    saved[key] = value
                end,
            },
            toc = {
                getTocTitleByPage = function()
                    return "The Frog-King"
                end,
            },
            getCurrentPage = function()
                return 12
            end,
        }

        local ok = ResumeSnippet.capture(ui, {
            screen = {
                getWidth = function() return 100 end,
                getHeight = function() return 200 end,
            },
        })

        assert.is_true(ok)
        assert.equals("In the olden days, when wishing still helped", saved.bookshelf_resume_snippet)
        assert.equals("The Frog-King", saved.bookshelf_resume_chapter)
        assert.is_true(cleared)
    end)

    it("falls back to pdf page text boxes", function()
        local saved = {}
        local ui = {
            document = {
                getPageText = function()
                    return {
                        { { word = "In" }, { word = "the" } },
                        { { word = "olden" }, { word = "days" } },
                    }
                end,
            },
            doc_settings = {
                saveSetting = function(_, key, value)
                    saved[key] = value
                end,
            },
            getCurrentPage = function()
                return 3
            end,
        }

        assert.is_true(ResumeSnippet.capture(ui, {}))
        assert.equals("In the olden days", saved.bookshelf_resume_snippet)
    end)

    it("declines while a user text selection is active", function()
        local saved = {}
        local ui = {
            document = {
                getTextFromPositions = function()
                    error("must not touch the document during a user selection")
                end,
            },
            doc_settings = {
                saveSetting = function(_, key, value)
                    saved[key] = value
                end,
            },
            highlight = {
                selected_text = { text = "user is selecting" },
            },
        }

        assert.is_false(ResumeSnippet.capture(ui, {}))
        assert.is_nil(saved.bookshelf_resume_snippet)
    end)

    it("declines gracefully when no text is available", function()
        local saved = {}
        local ui = {
            document = {
                getPageText = function()
                    return {}
                end,
            },
            doc_settings = {
                saveSetting = function(_, key, value)
                    saved[key] = value
                end,
            },
            getCurrentPage = function()
                return 3
            end,
        }

        assert.is_false(ResumeSnippet.capture(ui, {}))
        assert.is_nil(saved.bookshelf_resume_snippet)
    end)
end)
