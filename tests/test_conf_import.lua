--[[--
Unit tests for M10 confimport.lua (desktop-side conf import).

Run locally with:
    lua tests/test_conf_import.lua

File IO is fully injected (opts.read_fn/write_fn) — no real disk access,
no datastorage dependency. Covers the 3rd-round review edge list (plan
§十一 v2): BOM/CRLF, first-'='-split, empty values, duplicate keys,
illegal lines, type-by-DEFAULTS (vault "123" stays string), whitelist
type filtering, template self-import protection (F1), fingerprint
stability (no re-import on unchanged / line-ending-only change).
--]]--

package.path = package.path .. ";./plugin/fns_sync.koplugin/?.lua"

package.preload["gettext"] = function()
    return function(s) return s end
end
package.preload["logger"] = function()
    return {
        warn = function() end,
        info = function() end,
        dbg = function() end,
        err = function() end,
    }
end

local ConfImport = require("confimport")
local Config = require("config")

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

print("== M10 conf import ==")

-- ── normalize: BOM / CRLF / lone CR ──
do
    check("normalize: BOM stripped", ConfImport._normalize("\xEF\xBB\xBFabc") == "abc")
    check("normalize: CRLF → LF", ConfImport._normalize("a\r\nb") == "a\nb")
    check("normalize: lone CR → LF", ConfImport._normalize("a\rb") == "a\nb")
end

-- ── hash: stable, line-ending-insensitive ──
do
    local h1 = ConfImport._content_hash(ConfImport._normalize("k = v\r\nj = w\n"))
    local h2 = ConfImport._content_hash(ConfImport._normalize("k = v\nj = w\n"))
    local h3 = ConfImport._content_hash(ConfImport._normalize("k = CHANGED\nj = w\n"))
    check("hash: CRLF vs LF identical after normalize", h1 == h2)
    check("hash: different content differs", h1 ~= h3)
end

-- ── parse: basics + edge lines ──
do
    local out, warns = ConfImport._parse([[
# comment line
ai_enabled = true

server_url = https://fns.example.com
vault = 123
api_token = abc==def==
not a pair line
= novalue
ai_model = m1
ai_model = m2
ai_max_tokens = notanumber
show_page_number = maybe
]])
    check("parse: bool true", out.ai_enabled == true)
    check("parse: url string", out.server_url == "https://fns.example.com")
    check("parse: '123' vault stays string (typed by DEFAULTS)", out.vault == "123")
    check("parse: value with == split at FIRST '='", out.api_token == "abc==def==")
    check("parse: duplicate key last wins", out.ai_model == "m2")
    check("parse: bad number skipped", out.ai_max_tokens == nil)
    check("parse: bad bool skipped", out.show_page_number == nil)
    check("parse: no-'='-line warned", #warns >= 1)
    -- warnings mention the offending lines
    local warned = table.concat(warns, ";")
    check("parse: empty-key warned", warned:find("empty key") ~= nil)
    check("parse: duplicate warned", warned:find("duplicate") ~= nil)
    check("parse: bad number warned", warned:find("non%-numeric") ~= nil)
end

-- ── empty value semantics: string key clears, others skip+warn ──
do
    local out, warns = ConfImport._parse("ai_api_key =\nai_max_tokens =\n")
    check("empty value: string key cleared to \"\"", out.ai_api_key == "")
    check("empty value: number key skipped", out.ai_max_tokens == nil)
    check("empty value: number skip warned", #warns >= 1)
end

-- ── whitelist: type filtering (F2) ──
do
    check("whitelist: server_url importable", ConfImport._should_import("server_url") == true)
    check("whitelist: ai_api_key importable", ConfImport._should_import("ai_api_key") == true)
    check("whitelist: enabled importable", ConfImport._should_import("enabled") == true)
    check("whitelist: table key rejected (book_overrides)", ConfImport._should_import("book_overrides") == false)
    check("whitelist: table key rejected (ai_quick_prompts)", ConfImport._should_import("ai_quick_prompts") == false)
    check("whitelist: multi-line template rejected (note_template)", ConfImport._should_import("note_template") == false)
    check("whitelist: multi-line template rejected (excerpt_template)", ConfImport._should_import("excerpt_template") == false)
    check("whitelist: unknown key rejected", ConfImport._should_import("nonexistent_key") == false)

    -- integrated: a table key present in conf content is warned, not imported
    local out, warns = ConfImport._parse("note_template = oneline")
    check("whitelist: note_template not imported via parse", out.note_template == nil)
    check("whitelist: note_template warned", table.concat(warns):find("not importable") ~= nil)
end

-- ── template: fully commented (F1 double protection, layer 1) ──
do
    local effective = 0
    for line in ConfImport._TEMPLATE:gmatch("[^\n]+") do
        local t = line:match("^%s*(.-)%s*$")
        if t ~= "" and t:sub(1, 1) ~= "#" and t:find("=", 1, true) then
            effective = effective + 1
        end
    end
    check("template: zero effective key=value lines", effective == 0)
end

-- ── checkAndImport: lifecycle via injected IO ──
do
    local disk = nil  -- current conf content on "disk"
    local read_fn = function() return disk end
    local write_fn = function(_, content) disk = content; return true end
    -- path is required so checkAndImport never resolves the default
    -- (real-device) path — which would require KOReader's datastorage.
    local OPTS = { read_fn = read_fn, write_fn = write_fn, path = "TEST/fns_sync.conf" }
    local opts = function() return OPTS end

    -- 1. missing file → template written, hash recorded, nothing imported
    local s = { ai_api_key = "orig", server_url = "" }
    local r1 = ConfImport.checkAndImport(s, nil, opts())
    check("lifecycle: template created", r1.template_created == true)
    check("lifecycle: template hash returned", r1.hash ~= nil)
    check("lifecycle: nothing imported from template", #r1.imported == 0)
    check("lifecycle: settings untouched by template", s.ai_api_key == "orig")

    -- 2. F1 layer 2: passing the template hash back → no re-import
    local r2 = ConfImport.checkAndImport(s, r1.hash, opts())
    check("lifecycle: same hash → no import", #r2.imported == 0 and r2.template_created == nil)

    -- 3. user edits the conf → partial import
    disk = disk:gsub("#ai_api_key = sk%-xxxxxxxxxxxxxxxxxxxxxxxx",
                     "ai_api_key = sk-real-key-12345")
    disk = disk:gsub("#enabled = false", "enabled = true")
    local r3 = ConfImport.checkAndImport(s, r2.hash, opts())
    check("lifecycle: edited conf imports 2 keys", #r3.imported == 2)
    check("lifecycle: api key imported", s.ai_api_key == "sk-real-key-12345")
    check("lifecycle: mode switch imported", s.enabled == true)
    check("lifecycle: untouched keys preserved", s.server_url == "")

    -- 4. unchanged after import → no re-import (menu edits stay safe)
    local r4 = ConfImport.checkAndImport(s, r3.hash, opts())
    check("lifecycle: unchanged → no import", #r4.imported == 0)

    -- 5. line-ending-only edit (Windows editor) → same normalized hash → no import
    disk = disk:gsub("\n", "\r\n")
    local r5 = ConfImport.checkAndImport(s, r3.hash, opts())
    check("lifecycle: CRLF-only change → no re-import", r5.hash == r3.hash and #r5.imported == 0)

    -- 6. onResetConfig equivalent: fresh settings table + SAME stored hash
    --    → no re-import (fingerprint is caller-owned, top-level key)
    local fresh = {}
    for k, v in pairs(Config.DEFAULTS) do fresh[k] = v end
    local r6 = ConfImport.checkAndImport(fresh, r3.hash, opts())
    check("lifecycle: reset (fresh table, same hash) → no re-import", #r6.imported == 0)
    check("lifecycle: reset keeps DEFAULT api key", fresh.ai_api_key == Config.DEFAULTS.ai_api_key)
end

print(("%s passed, %s failed"):format(tests_passed, tests_failed))
os.exit(tests_failed == 0 and 0 or 1)
