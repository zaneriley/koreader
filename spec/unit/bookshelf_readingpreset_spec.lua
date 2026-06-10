describe("Bookshelf reading preset", function()
    local ReadingPreset

    setup(function()
        require("commonrequire")
        ReadingPreset = dofile("plugins/bookshelf.koplugin/readingpreset.lua")
    end)

    describe("language gating", function()
        it("applies to declared languages and their regional variants", function()
            local preset = { languages = { "en" } }
            assert.is_true(ReadingPreset.appliesToLanguage(preset, "en"))
            assert.is_true(ReadingPreset.appliesToLanguage(preset, "EN"))
            assert.is_true(ReadingPreset.appliesToLanguage(preset, "en-US"))
        end)

        it("declines other languages, missing language, and undeclared presets", function()
            local preset = { languages = { "en" } }
            assert.is_false(ReadingPreset.appliesToLanguage(preset, "ja"))
            assert.is_false(ReadingPreset.appliesToLanguage(preset, "enx"))
            assert.is_false(ReadingPreset.appliesToLanguage(preset, nil))
            assert.is_false(ReadingPreset.appliesToLanguage(preset, ""))
            assert.is_false(ReadingPreset.appliesToLanguage({}, "en"))
            assert.is_false(ReadingPreset.appliesToLanguage(nil, "en"))
        end)

        it("scopes the literary-latin preset to English", function()
            local preset = ReadingPreset.getPreset("literary-latin")
            assert.is_true(ReadingPreset.appliesToLanguage(preset, "en"))
            assert.is_false(ReadingPreset.appliesToLanguage(preset, "ja"))
        end)
    end)

    describe("publisher template repair", function()
        it("repairs Project Gutenberg template noise", function()
            local css = ReadingPreset.publisherRepairCss({
                identifiers = "URI:http://www.gutenberg.org/2591",
            })
            assert.is_truthy(css:find("letter-spacing: normal", 1, true))
            assert.is_truthy(css:find("word-spacing: normal", 1, true))
            assert.is_truthy(css:find("background-color: transparent", 1, true))
        end)

        it("never touches unidentified publishers", function()
            assert.is_nil(ReadingPreset.publisherRepairCss({
                identifiers = "urn:isbn:9784101010014",
            }))
            assert.is_nil(ReadingPreset.publisherRepairCss({}))
            assert.is_nil(ReadingPreset.publisherRepairCss(nil))
        end)
    end)
end)
