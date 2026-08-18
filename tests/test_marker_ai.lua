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

-- 19-26. cascadeDeleteAi (2026-08-15 user decision B1/B2/B4):
-- AI@ blocks are attachments of their host HL@; when the host is deleted,
-- its AI@ blocks go with it. B4 safety net: >AI_CASCADE_DELETE_MAX
-- candidates in one call → skip cascade entirely (return n_skipped).
local Config = require("config")

-- 19. cascade: host deleted → its AI@ blocks removed, others untouched
do
    local segs = {
        { type = "hl",  ts = "hl-2", content = "保留的摘录" },
        { type = "ai",  ts = "ai-1", content = "被删宿主的回答 1",
          meta = { hl = "hl-1", model = "m" } },
        { type = "ai",  ts = "ai-2", content = "被删宿主的回答 2",
          meta = { hl = "hl-1", model = "m" } },
        { type = "ai",  ts = "ai-3", content = "保留宿主的回答",
          meta = { hl = "hl-2", model = "m" } },
        { type = "ai",  ts = "ai-4", content = "孤儿回答",
          meta = { hl = "hl-9", model = "m" } },
    }
    local out, n_cascaded, n_skipped = Marker.cascadeDeleteAi(segs, { "hl-1" })
    check("cascade: 2 blocks cascaded", n_cascaded == 2)
    check("cascade: 0 skipped", n_skipped == 0)
    check("cascade: 3 segments remain (1 HL + other AI + orphan AI)", #out == 3)
    check("cascade: host HL kept", out[1].ts == "hl-2")
    check("cascade: other-host AI kept", out[2].ts == "ai-3")
    check("cascade: orphan AI kept (B3: not our business)", out[3].ts == "ai-4")
    check("cascade: input not modified", #segs == 5)
end

-- 20. cascade: empty deleted list → no-op passthrough
do
    local segs = { { type = "hl", ts = "hl-1", content = "x" } }
    local out, n_cascaded, n_skipped = Marker.cascadeDeleteAi(segs, {})
    check("cascade empty: no-op, same table returned", out == segs)
    check("cascade empty: n_cascaded == 0", n_cascaded == 0)
end

-- 21. cascade: B4 threshold — 11 candidates → skip entirely
do
    local segs = {}
    for i = 1, 11 do
        table.insert(segs, { type = "ai", ts = "ai-" .. i, content = "c" .. i,
            meta = { hl = "hl-1", model = "m" } })
    end
    local out, n_cascaded, n_skipped = Marker.cascadeDeleteAi(segs, { "hl-1" })
    check("cascade threshold: 11 candidates → skipped", n_skipped == 11)
    check("cascade threshold: n_cascaded == 0", n_cascaded == 0)
    check("cascade threshold: segments unchanged", #out == 11)
end

-- 22. cascade: exactly at threshold (10) → deleted
do
    local segs = {}
    for i = 1, 10 do
        table.insert(segs, { type = "ai", ts = "ai-" .. i, content = "c" .. i,
            meta = { hl = "hl-1", model = "m" } })
    end
    local out, n_cascaded, n_skipped = Marker.cascadeDeleteAi(segs, { "hl-1" })
    check("cascade at-threshold: 10 deleted", n_cascaded == 10 and n_skipped == 0)
    check("cascade at-threshold: 0 remain", #out == 0)
    check("cascade threshold constant == 10 (config)", Config.AI_CASCADE_DELETE_MAX == 10)
end

-- 23. cascade: AI without meta.hl untouched
do
    local segs = {
        { type = "ai", ts = "ai-1", content = "无 hl 标记（异常但容忍）" },
    }
    local out, n_cascaded = Marker.cascadeDeleteAi(segs, { "hl-1" })
    check("cascade no-meta: untouched", n_cascaded == 0 and #out == 1)
end

-- 24. cascade: serialize round-trip after cascade
-- (ts values must be 19-char datetimes — parseOpenMarkerMeta hardcodes
-- "YYYY-MM-DD HH:MM:SS" length; see marker.lua parseOpenMarkerMeta.)
do
    local ts1 = "2026-08-15 10:00:01"  -- deleted host
    local ts2 = "2026-08-15 10:00:02"  -- kept host
    local ts3 = "2026-08-15 10:00:03"  -- AI of deleted host
    local ts4 = "2026-08-15 10:00:04"  -- AI of kept host
    local segs = Marker.parse(
        '<!-- HL@' .. ts2 .. ' -->\n原文\n<!-- /HL@' .. ts2 .. ' -->\n' ..
        '<!-- AI@' .. ts3 .. ' hl="' .. ts1 .. '" model="m" -->\n回答\n<!-- /AI@' .. ts3 .. ' -->\n' ..
        '<!-- AI@' .. ts4 .. ' hl="' .. ts2 .. '" model="m" -->\n保留\n<!-- /AI@' .. ts4 .. ' -->')
    local out = Marker.cascadeDeleteAi(segs, { ts1 })
    local content = Marker.serialize(out)
    check("cascade round-trip: deleted AI gone", content:find("AI@" .. ts3, 1, true) == nil)
    check("cascade round-trip: kept AI present", content:find("AI@" .. ts4, 1, true) ~= nil)
    check("cascade round-trip: HL present", content:find("HL@" .. ts2, 1, true) ~= nil)
end

-- 25. cascade after drain (integration): pending AI whose host HL was just
-- deleted must NOT come back as orphaned — cascade runs after drain.
do
    local pending = {
        { ts = "ai-1", hl_ts = "hl-1", content = "宿主已删的 pending 回答",
          model = "m", book_path = "/b" },
    }
    -- applyDiff already removed hl-1; segments now only hold another HL
    local segs = { { type = "hl", ts = "hl-2", content = "别的摘录" } }
    local _, drained_segs = Marker.drainAiBlocks(pending, segs, "/b")
    -- drain appends ai-1 as orphaned at end; cascade must remove it
    local out = Marker.cascadeDeleteAi(drained_segs, { "hl-1" })
    check("drain+cascade: orphaned AI for deleted host removed", #out == 1)
    check("drain+cascade: only the other HL remains", out[1].ts == "hl-2")
end

-- 26. cascade: mixed deleted hosts (multi-host delete round)
do
    local segs = {
        { type = "hl", ts = "hl-3", content = "保留" },
        { type = "ai", ts = "ai-1", content = "a", meta = { hl = "hl-1" } },
        { type = "ai", ts = "ai-2", content = "b", meta = { hl = "hl-2" } },
        { type = "ai", ts = "ai-3", content = "c", meta = { hl = "hl-3" } },
    }
    local out, n_cascaded = Marker.cascadeDeleteAi(segs, { "hl-1", "hl-2" })
    check("cascade multi-host: 2 cascaded", n_cascaded == 2)
    check("cascade multi-host: HL-3 + its AI remain", #out == 2
        and out[1].ts == "hl-3" and out[2].ts == "ai-3")
end

-- 27. Q+A merged content (2026-08-18 main.lua change): _addAiContentToNote
-- writes "【问】…\n\n【答】…" into the AI@ block — quick prompts record a
-- short label (翻译/解释/评论), hand-typed questions drop the embedded
-- original text entirely (no placeholder). Marker layer must treat it as
-- opaque: drain→serialize→parse→serialize stable, labels and special
-- chars intact.
do
    local q_a = "【问】\n翻译\n\n【答】\n这是一段翻译。\n\n第二段 (含特殊字符 %d 与括号)。"
    local pending = {
        { ts = "2026-08-18 10:00:01", hl_ts = "2026-08-18 10:00:00", content = q_a,
          model = "deepseek-chat", book_path = "/b" },
    }
    local segs = { { type = "hl", ts = "2026-08-18 10:00:00", content = "原文" } }
    local _, new_segs = Marker.drainAiBlocks(pending, segs, "/b")
    local out1 = Marker.serialize(new_segs)
    local out2 = Marker.serialize(Marker.parse(out1))
    check("qa: drain→serialize→parse→serialize stable", out2 == out1)
    local parsed_ai
    for _, s in ipairs(Marker.parse(out1)) do
        if s.type == "ai" then parsed_ai = s break end
    end
    check("qa: content preserved verbatim", parsed_ai ~= nil and parsed_ai.content == q_a)
    check("qa: 【问】 label intact", out1:find("【问】", 1, true) ~= nil)
    check("qa: 【答】 label intact", out1:find("【答】", 1, true) ~= nil)
end

print(("== Tests: %d passed, %d failed =="):format(tests_passed, tests_failed))
os.exit(tests_failed == 0 and 0 or 1)
