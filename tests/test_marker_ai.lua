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

-- 10. Orphaned AI@ meta round-trip (M8 Task E-step1 review guard)
-- drain helper falls back to "append at end + orphaned=true" when hl_ts doesn't
-- match any HL@ segment. The orphaned meta must round-trip through serialize→parse
-- to survive future sync rounds.
do
    local segs = {
        { type = "hl", ts = "2026-08-12 21:18:58", content = "原文" },
        { type = "ai", ts = "2026-08-13 14:47:51", content = "AI 回答",
          meta = { hl = "2026-08-13 14:27:20", model = "deepseek-v4-flash", orphaned = "true" } },
    }
    local out1 = Marker.serialize(segs)
    local out2 = Marker.serialize(Marker.parse(out1))
    check("orphaned: round-trip stable", out2 == out1)
    check("orphaned: meta preserved", out2:find('orphaned="true"') ~= nil)
end

-- 11. drainAiBlocks: empty pending returns empty drained, segments unchanged
do
    local segs = { { type = "hl", ts = "ts1", content = "原文" } }
    local drained, new_segs = Marker.drainAiBlocks({}, segs, "/path/book.epub")
    check("drain: empty pending -> empty drained", #drained == 0)
    check("drain: empty pending -> segments unchanged", #new_segs == 1)
end

-- 12. drainAiBlocks: book_path mismatch skips block (H-5 fix)
do
    local pending = {
        { ts = "ai-ts1", hl_ts = "hl-ts1", content = "AI 内容",
          model = "deepseek-chat", book_path = "/other/book.epub" },
    }
    local segs = { { type = "hl", ts = "hl-ts1", content = "原文" } }
    local drained, new_segs = Marker.drainAiBlocks(pending, segs, "/this/book.epub")
    check("drain: book_path mismatch -> drained empty", #drained == 0)
    check("drain: book_path mismatch -> segments unchanged", #new_segs == 1)
    check("drain: pending input NOT modified", #pending == 1)
end

-- 13. drainAiBlocks: matching HL@ found → AI@ inserted right after HL@
do
    local pending = {
        { ts = "ai-ts1", hl_ts = "hl-ts1", content = "AI 内容",
          model = "deepseek-chat", book_path = "/book.epub" },
    }
    local segs = {
        { type = "hl", ts = "hl-ts1", content = "原文" },
        { type = "user", content = "用户笔记" },
    }
    local drained, new_segs = Marker.drainAiBlocks(pending, segs, "/book.epub")
    check("drain: 1 block drained", #drained == 1)
    check("drain: 3 segments total", #new_segs == 3)
    check("drain: AI@ inserted at position 2 (after HL@)", new_segs[2].type == "ai")
    check("drain: AI@ has hl meta", new_segs[2].meta and new_segs[2].meta.hl == "hl-ts1")
    check("drain: AI@ has NO orphaned meta", new_segs[2].meta.orphaned == nil)
    check("drain: pending input NOT modified", #pending == 1)
    check("drain: original segments NOT modified", #segs == 2)
end

-- 14. drainAiBlocks: no matching HL@ → orphaned fallback append at end
do
    local pending = {
        { ts = "ai-ts1", hl_ts = "missing-hl", content = "AI 内容",
          model = "deepseek-chat", book_path = "/book.epub" },
    }
    local segs = {
        { type = "hl", ts = "hl-ts1", content = "原文" },
    }
    local drained, new_segs = Marker.drainAiBlocks(pending, segs, "/book.epub")
    check("drain: orphaned drained", #drained == 1)
    check("drain: orphaned appended at end", new_segs[2].type == "ai")
    check("drain: orphaned has orphaned=true meta", new_segs[2].meta.orphaned == "true")
end

-- 15. drainAiBlocks: H-4 fix — multiple AI@ for same HL@ preserve enqueue order
do
    local pending = {
        { ts = "ai-1", hl_ts = "hl-1", content = "AI 第一条",
          model = "m", book_path = "/b" },
        { ts = "ai-2", hl_ts = "hl-1", content = "AI 第二条",
          model = "m", book_path = "/b" },
        { ts = "ai-3", hl_ts = "hl-1", content = "AI 第三条",
          model = "m", book_path = "/b" },
    }
    local segs = { { type = "hl", ts = "hl-1", content = "原文" } }
    local drained, new_segs = Marker.drainAiBlocks(pending, segs, "/b")
    check("drain: 3 drained in order", #drained == 3)
    check("drain: H-4 order ai-1 first", new_segs[2].ts == "ai-1")
    check("drain: H-4 order ai-2 second", new_segs[3].ts == "ai-2")
    check("drain: H-4 order ai-3 third", new_segs[4].ts == "ai-3")
end

-- 16. drainAiBlocks: drain must NOT modify pending_blocks (caller manages commit)
-- This is the CRITICAL fix: previously drain cleared pending in-place, causing
-- AI@ blocks to be lost when POST failed. Now drain is read-only on pending.
do
    local pending = {
        { ts = "ai-1", hl_ts = "hl-1", content = "AI 内容",
          model = "m", book_path = "/b" },
    }
    local segs = { { type = "hl", ts = "hl-1", content = "原文" } }
    local drained, _ = Marker.drainAiBlocks(pending, segs, "/b")
    check("drain: caller can still commit (drained non-empty)", #drained == 1)
    check("drain: pending still has block (NOT cleared)", #pending == 1)
    check("drain: pending block identity preserved (caller can remove by ref/ts)",
        pending[1].ts == "ai-1")
end

-- 17. drainAiBlocks: serialize after drain must be idempotent (regression guard)
do
    local pending = {
        { ts = "ai-1", hl_ts = "hl-1", content = "AI 内容",
          model = "m", book_path = "/b" },
    }
    local segs = { { type = "hl", ts = "hl-1", content = "原文" } }
    local _, new_segs = Marker.drainAiBlocks(pending, segs, "/b")
    local out1 = Marker.serialize(new_segs)
    local out2 = Marker.serialize(Marker.parse(out1))
    check("drain: serialize(parse(serialize(drained_segs))) stable", out2 == out1)
end

-- 18. drainAiBlocks: mixed book_path (2 match + 1 mismatch) — code-reviewer gap
-- Verifies H-5 filtering + drained only contains matching blocks + mismatched
-- ones stay in pending input (caller will re-drain on original book's sync).
do
    local pending = {
        { ts = "ai-1", hl_ts = "hl-1", content = "本 book 第一条",
          model = "m", book_path = "/this" },
        { ts = "ai-2", hl_ts = "hl-1", content = "本 book 第二条",
          model = "m", book_path = "/this" },
        { ts = "ai-3", hl_ts = "hl-9", content = "其他 book",
          model = "m", book_path = "/other" },
    }
    local segs = { { type = "hl", ts = "hl-1", content = "原文" } }
    local drained, new_segs = Marker.drainAiBlocks(pending, segs, "/this")
    check("drain mixed: 2 matching drained", #drained == 2)
    check("drain mixed: ai-1 drained", drained[1].ts == "ai-1")
    check("drain mixed: ai-2 drained", drained[2].ts == "ai-2")
    check("drain mixed: 3 segments (1 HL + 2 AI)", #new_segs == 3)
    check("drain mixed: H-4 order preserved", new_segs[2].ts == "ai-1" and new_segs[3].ts == "ai-2")
    check("drain mixed: pending input NOT modified (3 blocks still)", #pending == 3)
end

print(("== Tests: %d passed, %d failed =="):format(tests_passed, tests_failed))
os.exit(tests_failed == 0 and 0 or 1)
