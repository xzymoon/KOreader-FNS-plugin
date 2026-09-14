--[[--
Unit tests for M11 i18n (English UI translations).

Run locally with:
    lua tests/test_i18n.lua

Covers:
- i18n.needsEnglish / i18n.merge pure logic
- locale/en_US.lua data integrity (non-empty string keys and values)
- source coverage: every _("...") msgid in the plugin sources must have
  an entry in en_US.lua (whitelisted English-original strings excepted),
  so newly added UI strings can't ship untranslated silently
- placeholder fidelity: %d/%s/%1/%2 and {word} placeholders must match
  between msgid and translation
--]]--

package.path = package.path .. ";./plugin/fns_sync.koplugin/?.lua"

local I18n = require("i18n")
local en = require("locale/en_US")

local tests_passed = 0
local tests_failed = 0

local function check(name, cond)
    if cond then
        tests_passed = tests_passed + 1
        print(("  PASS  %s"):format(name))
    else
        tests_failed = tests_failed + 1
        print(("  FAIL  %s"):format(name))
    end
end

print("== M11 i18n ==")

-- ── needsEnglish ──
-- KOReader's language menu stores "English" as "C" and offers no en_US;
-- an unset language (nil) is the default English UI. All three must
-- map to true, or the main audience never gets translations (review HIGH-1).
do
    check("needsEnglish: nil (default English UI) → true", I18n.needsEnglish(nil) == true)
    check("needsEnglish: C (menu \"English\") → true", I18n.needsEnglish("C") == true)
    check("needsEnglish: en_GB → true", I18n.needsEnglish("en_GB") == true)
    check("needsEnglish: en → true", I18n.needsEnglish("en") == true)
    check("needsEnglish: zh_CN → false", I18n.needsEnglish("zh_CN") == false)
    check("needsEnglish: empty string → false", I18n.needsEnglish("") == false)
    check("needsEnglish: non-string (42) → false", I18n.needsEnglish(42) == false)
end

-- ── merge ──
do
    local target = { existing = "old" }
    I18n.merge(target, { existing = "new", added = "v" })
    check("merge: overwrites existing key", target.existing == "new")
    check("merge: adds new key", target.added == "v")
    I18n.merge(target, { existing = "new" })
    check("merge: idempotent re-merge", target.existing == "new" and target.added == "v")
end

-- ── en_US.lua data integrity ──
do
    local count = 0
    local bad = {}
    for k, v in pairs(en) do
        count = count + 1
        if type(k) ~= "string" or k == "" then table.insert(bad, "key not non-empty string")
        elseif type(v) ~= "string" or v == "" then table.insert(bad, k) end
    end
    check(("integrity: %d entries, all non-empty strings"):format(count),
        #bad == 0 and count > 150)
    for _, b in ipairs(bad) do print("        bad entry: " .. tostring(b)) end
end

-- ── source coverage: every _("...") msgid must be translated ──
do
    -- Msgids that are already English (or deliberately untranslated):
    local whitelist = {
        ["FNS Sync"] = true,
        ["Sync highlights and notes to Obsidian via Fast Note Sync service."] = true,
        ["max_tokens"] = true,
        ["temperature"] = true,
        ["network unreachable"] = true,
        ["non-JSON response: "] = true,
        ["..."] = true,
    }
    -- All module files, not just the ones that currently contain _()
    -- (main/api/ai/_meta) — a new _("...") in any other module must
    -- fail this test, not silently ship untranslated.
    local sources = {
        "main.lua", "api.lua", "ai.lua", "_meta.lua", "config.lua",
        "excerpt.lua", "localstore.lua", "confimport.lua", "gate.lua",
        "marker.lua", "threeway.lua",
    }
    local msgids = {}
    for _, fname in ipairs(sources) do
        local path = "plugin/fns_sync.koplugin/" .. fname
        local f = io.open(path, "r")
        if not f then
            check("source coverage: can open " .. path, false)
        else
            local text = f:read("*a")
            f:close()
            -- Plain-find scan for _("..."): start after the literal `_("`
            -- and cut at the next literal `")`. A `")` hit is skipped
            -- when the quote is escaped (preceded by a backslash), so
            -- msgids containing \"...\") stay intact. A plain pattern
            -- capture can't express "cut before the closing two-char
            -- sequence" (capture groups swallow the trailing quote),
            -- hence the manual slicing.
            local init = 1
            while true do
                local s1 = text:find('_("', init, true)
                if not s1 then break end
                local content_start = s1 + 3
                local e2 = text:find('")', content_start, true)
                while e2 and text:sub(e2 - 1, e2 - 1) == "\\" do
                    e2 = text:find('")', e2 + 1, true)
                end
                if not e2 then break end
                -- Un-escape source-level escapes so the extracted msgid
                -- equals what _("...") evaluates to at runtime (\n is a
                -- real newline in the loaded module, not two chars).
                local msgid = text:sub(content_start, e2 - 1):gsub("\\(.)", function(c)
                    if c == "n" then return "\n" end
                    if c == "t" then return "\t" end
                    if c == "r" then return "\r" end
                    return c
                end)
                msgids[msgid] = true
                init = e2 + 2
            end
        end
    end

    local missing = {}
    for msgid in pairs(msgids) do
        if not whitelist[msgid] and en[msgid] == nil then
            table.insert(missing, msgid)
        end
    end
    table.sort(missing)
    check(("source coverage: %d unique msgids, 0 missing translations"):format(
        (function() local n = 0 for _ in pairs(msgids) do n = n + 1 end return n end)()),
        #missing == 0)
    for _, m in ipairs(missing) do print("        missing: " .. m) end

    -- Reverse direction: en_US.lua keys that no source references (and
    -- that aren't whitelisted) are stale leftovers from msgid changes.
    local orphans = {}
    for k in pairs(en) do
        if not msgids[k] and not whitelist[k] then table.insert(orphans, k) end
    end
    table.sort(orphans)
    check("source coverage: 0 orphan translations (stale keys)", #orphans == 0)
    for _, o in ipairs(orphans) do print("        orphan: " .. o) end
end

-- ── placeholder fidelity ──
do
    local function placeholders(s)
        local set = {}
        for p in s:gmatch("%%[ds123]") do set[p] = (set[p] or 0) + 1 end
        for p in s:gmatch("%{%a+%}") do set[p] = (set[p] or 0) + 1 end
        -- Compound {{VALUE:field}} placeholders: contents may be localized
        -- (字段 vs field), so only count the double-brace occurrences.
        set["{{"] = select(2, s:gsub("{{", ""))
        return set
    end
    local same = function(a, b)
        for k, v in pairs(a) do if b[k] ~= v then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    local bad = {}
    for k, v in pairs(en) do
        if not same(placeholders(k), placeholders(v)) then
            table.insert(bad, k)
        end
    end
    table.sort(bad)
    check("placeholders: all %d/%s/%1/{word} sets match", #bad == 0)
    for _, b in ipairs(bad) do print("        mismatch: " .. b) end
end

print(("%s passed, %s failed"):format(tests_passed, tests_failed))
os.exit(tests_failed == 0 and 0 or 1)
