--[[--
Unit tests for M8 AI@ block support in marker.lua.

Run locally (NOT on Kindle) with:
    lua tests/test_marker_ai.lua
--]]--

package.path = package.path .. ";./plugin/fns_sync.koplugin/?.lua"

-- Mock gettext (KOreader provides this globally at runtime)
package.preload["gettext"] = function()
    return function(s) return s end
end

-- Mock logger (KOreader provides this globally at runtime). marker.lua uses
-- logger.warn for malformed-input diagnostics; tests need it to be a no-op.
package.preload["logger"] = function()
    return {
        warn = function() end,
        info = function() end,
        dbg = function() end,
        err = function() end,
    }
end

local Marker = require("marker")

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

print("== M8 AI@ block support ==")

-- 1. Parse a single AI@ block
do
    local content = '<!-- AI@2026-08-12 19:48:00 hl="2026-08-12 19:45:00" model="deepseek-chat" -->\nAI 总结的内容\n<!-- /AI@2026-08-12 19:48:00 -->'
    local segs = Marker.parse(content)
    check("parse: 1 segment", #segs == 1)
    check("parse: type == ai", segs[1].type == "ai")
    check("parse: ts extracted", segs[1].ts == "2026-08-12 19:48:00")
    check("parse: hl meta", segs[1].meta and segs[1].meta.hl == "2026-08-12 19:45:00")
    check("parse: model meta", segs[1].meta and segs[1].meta.model == "deepseek-chat")
    check("parse: body content", segs[1].content:find("AI 总结的内容") ~= nil)
end

-- 2. Round-trip: parse → serialize preserves AI@ block
do
    local original = '<!-- AI@2026-08-12 19:48:00 hl="2026-08-12 19:45:00" model="deepseek-chat" -->\nAI 内容\n<!-- /AI@2026-08-12 19:48:00 -->'
    local segs = Marker.parse(original)
    local again = Marker.serialize(segs)
    check("round-trip: AI@ block preserved", again:find("AI@2026%-08%-12 19:48:00") ~= nil)
    check("round-trip: close marker preserved", again:find("/AI@2026%-08%-12 19:48:00") ~= nil)
    check("round-trip: hl meta preserved", again:find('hl="2026%-08%-12 19:45:00"') ~= nil)
    check("round-trip: model meta preserved", again:find('model="deepseek%-chat"') ~= nil)
end

-- 3. Mixed: HL@ + AI@ + user content
do
    local content = '<!-- HL@2026-08-12 19:45:00 -->\n原文\n<!-- /HL@2026-08-12 19:45:00 -->\n\n用户笔记\n\n<!-- AI@2026-08-12 19:48:00 hl="2026-08-12 19:45:00" model="deepseek-chat" -->\nAI 内容\n<!-- /AI@2026-08-12 19:48:00 -->'
    local segs = Marker.parse(content)
    local hl_count, ai_count, user_count = 0, 0, 0
    for _, s in ipairs(segs) do
        if s.type == "hl" then hl_count = hl_count + 1
        elseif s.type == "ai" then ai_count = ai_count + 1
        elseif s.type == "user" then user_count = user_count + 1 end
    end
    check("mixed: 1 hl", hl_count == 1)
    check("mixed: 1 ai", ai_count == 1)
    check("mixed: >=1 user", user_count >= 1)
end

-- 4. Diff: AI blocks do NOT participate
do
    local existing = Marker.parse('<!-- AI@2026-08-12 19:48:00 hl="2026-08-12 19:45:00" model="deepseek-chat" -->\nAI 内容\n<!-- /AI@2026-08-12 19:48:00 -->')
    local actions = Marker.diff(existing, {}, {})
    local has_ai_delete = false
    for _, a in ipairs(actions) do
        if a.op == "delete" then has_ai_delete = true end
    end
    check("diff: AI block not deleted when current_highlights empty", not has_ai_delete)
    check("diff: no actions at all", #actions == 0)
end

-- 5. applyDiff preserves AI segments
do
    local existing = {
        { type = "ai", ts = "2026-08-12 19:48:00", content = "AI 内容",
          meta = { hl = "2026-08-12 19:45:00", model = "deepseek-chat" } },
        { type = "user", content = "用户笔记" },
    }
    local actions = {}
    local result = Marker.applyDiff(existing, actions)
    check("applyDiff: AI segment preserved", result[1].type == "ai")
    check("applyDiff: AI content preserved", result[1].content == "AI 内容")
    check("applyDiff: user segment preserved", result[2].type == "user")
end

-- 6. Serialize: HL@ → AI@ tight (decision 1 块间紧凑)
do
    local segs = {
        { type = "hl", ts = "2026-08-13 10:00:00", content = "原文高亮" },
        { type = "ai", ts = "2026-08-13 10:01:00", content = "AI 回答",
          meta = { hl = "2026-08-13 10:00:00", model = "deepseek-chat" } },
    }
    local out = Marker.serialize(segs)
    local hl_close = "<!-- /HL@2026-08-13 10:00:00 -->"
    local ai_open = "<!-- AI@2026-08-13 10:01:00"
    local hl_pos = out:find(hl_close, 1, true)
    local ai_pos = out:find(ai_open, 1, true)
    check("serialize: HL@ close marker found", hl_pos ~= nil)
    check("serialize: AI@ open marker found", ai_pos ~= nil)
    if hl_pos and ai_pos then
        local between = out:sub(hl_pos + #hl_close, ai_pos - 1)
        -- 决策 1：HL@ close 到 AI@ open 之间是 \n\n（serialize 显式加）
        check("serialize: HL@→AI@ separator is \\n\\n", between == "\n\n")
    end
end

-- 7. Idempotency (CRITICAL-1 regression guard): serialize→parse→serialize
-- must be stable. Previously _wrapAiBlock embedded \n\n inside the block,
-- causing parse to capture it as user content → next serialize grew +2 bytes.
do
    local segs = {
        { type = "hl", ts = "2026-08-13 10:00:00", content = "原文高亮" },
        { type = "ai", ts = "2026-08-13 10:01:00", content = "AI 回答",
          meta = { hl = "2026-08-13 10:00:00", model = "deepseek-chat" } },
    }
    local out1 = Marker.serialize(segs)
    local out2 = Marker.serialize(Marker.parse(out1))
    local out3 = Marker.serialize(Marker.parse(out2))
    check("idempotency: serialize(parse(out1)) == out1", out2 == out1)
    check("idempotency: serialize(parse(out2)) == out2 (no growth)", out3 == out2)
end

-- 8. Idempotency: multi AI@ stacking (decision 4)
do
    local segs = {
        { type = "hl", ts = "2026-08-13 10:00:00", content = "原文高亮" },
        { type = "ai", ts = "2026-08-13 10:01:00", content = "AI 回答 1",
          meta = { hl = "2026-08-13 10:00:00", model = "deepseek-chat" } },
        { type = "ai", ts = "2026-08-13 10:02:00", content = "AI 回答 2",
          meta = { hl = "2026-08-13 10:00:00", model = "deepseek-chat" } },
    }
    local out1 = Marker.serialize(segs)
    local out2 = Marker.serialize(Marker.parse(out1))
    check("idempotency: multi AI@ round-trip stable", out2 == out1)
end

-- 9. Idempotency: AI@ → HL@ (multi highlight scenario)
do
    local segs = {
        { type = "hl", ts = "2026-08-13 10:00:00", content = "原文 1" },
        { type = "ai", ts = "2026-08-13 10:01:00", content = "AI 回答",
          meta = { hl = "2026-08-13 10:00:00", model = "deepseek-chat" } },
        { type = "hl", ts = "2026-08-13 10:02:00", content = "原文 2" },
    }
    local out1 = Marker.serialize(segs)
    local out2 = Marker.serialize(Marker.parse(out1))
    check("idempotency: AI@→HL@ round-trip stable", out2 == out1)
end

print(("== Tests: %d passed, %d failed =="):format(tests_passed, tests_failed))
os.exit(tests_failed == 0 and 0 or 1)
