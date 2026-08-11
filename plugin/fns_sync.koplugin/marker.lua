--[[--
Item-level marker handling for FNS sync.

Each KOreader highlight is wrapped in an HL@ block in the Obsidian note:

    <!-- HL@<datetime> pos0="/body/..." pos1="/body/..." chapter="..." -->
    <excerpt content>
    <!-- /HL@<datetime> -->

The datetime is the KOreader annotation's datetime field (creation timestamp,
serves as a unique key per book). Text between HL@ blocks (or outside any
HL@ block) is treated as user-authored content and preserved verbatim
across syncs.

M7 (bidirectional sync): the open marker optionally carries META fields
(pos0/pos1/chapter) used to re-create highlights on other devices. The
fields are attached to the segment as `seg.meta` and travel with the HL@
block. Old notes without these fields parse with `seg.meta = nil`.

Public API:
  - parse(content)                              -> segments
  - serialize(segments)                         -> content
  - wrapBlock(ts, content, meta)                -> block string
  - diff(existing_segments, current_highlights, current_meta_map) -> actions
  - applyDiff(existing_segments, actions)       -> new_segments
  - parseOpenMarkerMeta(open_body)              -> meta table (or nil)

Limitations:
  - HL@ blocks must not be nested. KOreader datetimes are flat per-book, so
    this is naturally satisfied.
  - Malformed HL@ blocks (missing close marker) are treated as user content
    and preserved verbatim; they will not be diffed.

@module fns_sync.marker
--]]--

local logger = require("logger")

local Marker = {}

-- Marker token constants. string.find with plain=true is used everywhere,
-- so these are literal strings (no Lua pattern interpretation).
local HL_OPEN_PREFIX = "<!-- HL@"
local HL_OPEN_SUFFIX = " -->"
local HL_CLOSE_PREFIX = "<!-- /HL@"
local HL_CLOSE_SUFFIX = " -->"

-- Known META keys (M7). Anything else in the open marker is preserved
-- verbatim on round-trip but ignored by the diff logic.
local META_KEYS = { "pos0", "pos1", "chapter" }

--- Parse the body of an HL@ open marker (the part between `<!-- HL@` and ` -->`).
-- Format: `<datetime> [key1="value1" key2="value2" ...]`
-- datetime is always 19 chars: "YYYY-MM-DD HH:MM:SS".
-- Returns: ts_string, meta_table_or_nil
--   meta = { pos0 = "...", pos1 = "...", chapter = "..." } (only keys present in marker)
-- Parsing is plain-text (no Lua patterns) for safety with XPointer special chars.
-- On malformed input returns ts only with meta=nil (best effort).
function Marker.parseOpenMarkerMeta(open_body)
    if not open_body or #open_body < 19 then return open_body, nil end
    local ts = string.sub(open_body, 1, 19)
    -- Everything after ts + separating space (if any) is the META region.
    local meta = nil
    if #open_body >= 21 then
        local rest = string.sub(open_body, 21)  -- skip "YYYY-MM-DD HH:MM:SS "
        local i = 1
        while i <= #rest do
            -- Find next `="`
            local eq_pos = string.find(rest, "=\"", i, true)
            if not eq_pos then break end
            local key = string.sub(rest, i, eq_pos - 1)
            -- Trim trailing whitespace from key (in case of double-space)
            key = key:gsub("^%s+", ""):gsub("%s+$", "")
            local value_start = eq_pos + 2
            local value_end = string.find(rest, "\"", value_start, true)
            if not value_end then break end  -- malformed; bail
            local value = string.sub(rest, value_start, value_end - 1)
            if key ~= "" then
                meta = meta or {}
                meta[key] = value
            end
            -- Move past `" ` (closing quote + space). If at end of string, break.
            i = value_end + 1
            if i > #rest then break end
            -- Skip the single space separator
            if string.sub(rest, i, i) == " " then i = i + 1 end
        end
    end
    return ts, meta
end

--- Serialize a meta table back into open-marker body fragment.
-- Returns string like ` pos0="/body/..." pos1="/body/..." chapter="..."`
-- (with leading space), or empty string if meta is nil/empty.
-- Only serializes known META_KEYS to avoid round-trip drift from random input.
local function serializeMeta(meta)
    if not meta then return "" end
    local parts = {}
    for _, key in ipairs(META_KEYS) do
        local v = meta[key]
        if v ~= nil and v ~= "" then
            table.insert(parts, key .. "=\"" .. tostring(v) .. "\"")
        end
    end
    if #parts == 0 then return "" end
    return " " .. table.concat(parts, " ")
end

--- Parse notebook content into a list of segments.
-- Each segment is either:
--   { type = "user", content = "..." }                              -- user text (verbatim)
--   { type = "hl", ts = "...", content = "...", meta = {...}|nil }  -- KOreader highlight block
--
-- Malformed HL@ blocks (missing close marker, missing " -->") are treated as
-- user content (preserved verbatim, not lost).
function Marker.parse(content)
    local segments = {}
    local i = 1
    local n = #content

    while i <= n do
        local open_start = string.find(content, HL_OPEN_PREFIX, i, true)
        if not open_start then
            local rest = string.sub(content, i)
            table.insert(segments, { type = "user", content = rest })
            break
        end

        -- Capture text before HL@ as user content
        if open_start > i then
            local before = string.sub(content, i, open_start - 1)
            table.insert(segments, { type = "user", content = before })
        end

        -- Find the " -->" that closes the open marker
        local open_suffix_pos = string.find(content, HL_OPEN_SUFFIX, open_start, true)
        if not open_suffix_pos then
            logger.warn("[FNS] malformed HL@ open marker (no ' -->'), treating rest as user content")
            local rest = string.sub(content, open_start)
            table.insert(segments, { type = "user", content = rest })
            break
        end
        local open_body = string.sub(content, open_start + #HL_OPEN_PREFIX, open_suffix_pos - 1)
        -- M7: parse ts + optional meta fields. ts is the first 19 chars,
        -- the rest (if any) is `key="value"` META pairs. We use the ts
        -- from parseOpenMarkerMeta because the META region uses spaces as
        -- separators and XPointer values may contain "[" "]" "(" ")" "."
        -- but NOT spaces (verified from KOreader readerlink.lua samples).
        local ts, meta = Marker.parseOpenMarkerMeta(open_body)

        -- Find matching close marker "<!-- /HL@<ts> -->"
        local close_marker = HL_CLOSE_PREFIX .. ts .. HL_CLOSE_SUFFIX
        local close_pos = string.find(content, close_marker, open_suffix_pos + #HL_OPEN_SUFFIX, true)
        if not close_pos then
            logger.warn("[FNS] HL@ block missing close marker for ts=" .. tostring(ts) .. ", treating as user content")
            local rest = string.sub(content, open_start)
            table.insert(segments, { type = "user", content = rest })
            break
        end

        -- Extract block content; trim leading/trailing whitespace so diff
        -- comparisons aren't thrown off by incidental blank lines.
        local block_start = open_suffix_pos + #HL_OPEN_SUFFIX
        local raw_block = string.sub(content, block_start, close_pos - 1)
        -- Strip a trailing "\n> " if present — the close marker may be
        -- prefixed with "> " (see serialize comment) so it sits inside the
        -- blockquote. Without this strip, the trailing "> " would leak
        -- into segment content on the next parse and cause a diff loop.
        -- Matches both new format ("\n> ") and old format ("\n" only).
        raw_block = raw_block:gsub("\n%s*>%s*$", "")
        local trimmed = raw_block:gsub("^%s+", ""):gsub("%s+$", "")

        local seg = { type = "hl", ts = ts, content = trimmed }
        if meta then seg.meta = meta end
        table.insert(segments, seg)

        i = close_pos + #close_marker
    end

    return segments
end

--- Wrap a single highlight's content in HL@ markers.
-- Centralizes the block format so serialize (diff path for existing notes)
-- and external callers like renderFullNote (new note creation path) produce
-- identical output. Format (M7 with optional meta):
--   <!-- HL@<ts> pos0="/body/..." pos1="/body/..." chapter="..." -->
--   <content>
--
--   <!-- /HL@<ts> -->
--
-- The blank line before the close marker is LOAD-BEARING — it terminates
-- Markdown blockquote lazy continuation so Obsidian's blue blockquote bar
-- stops at the body's last visible line instead of extending to the marker.
--
-- @param ts string  highlight datetime (unique key per book)
-- @param content string  rendered excerpt body (should be trimmed of
--                        trailing newlines; renderExcerpt already does this)
-- @param meta table|nil  optional M7 meta { pos0, pos1, chapter } attached
--                        to the open marker for cross-device sync
-- @return string  wrapped block (head + body + blank line + close)
function Marker.wrapBlock(ts, content, meta)
    return HL_OPEN_PREFIX .. ts .. serializeMeta(meta) .. HL_OPEN_SUFFIX .. "\n"
        .. content .. "\n\n"
        .. HL_CLOSE_PREFIX .. ts .. HL_CLOSE_SUFFIX
end

--- Serialize segments back to notebook content.
-- Inverse of parse for well-formed input. Two adjacent HL@ blocks (no user
-- text between them — e.g. after a fresh insert) get TWO blank lines as
-- separator — gives a clear visual boundary in the source .md file between
-- distinct highlights. (Markdown rendering collapses consecutive blank
-- lines to a single paragraph break, so rendered view still shows one gap.)
-- M7: preserves seg.meta through round-trip (writes pos0/pos1/chapter into
-- the open marker).
function Marker.serialize(segments)
    local parts = {}
    for i, seg in ipairs(segments) do
        if seg.type == "user" then
            table.insert(parts, seg.content)
        elseif seg.type == "hl" then
            if i > 1 and segments[i - 1].type == "hl" then
                table.insert(parts, "\n\n\n")  -- two blank lines in source
            end
            table.insert(parts, Marker.wrapBlock(seg.ts, seg.content, seg.meta))
        end
    end
    return table.concat(parts)
end

--- Compute diff between existing note segments and current KOreader highlights.
-- @param existing_segments  result of parse(existing note content)
-- @param current_highlights  table { ts -> rendered_content } from excerpt.lua
-- @param current_meta_map    optional (M7) table { ts -> meta } from local
--                            annotations; attaches meta to insert/update actions
--                            so the new HL@ block carries pos0/pos1/chapter
--                            for cross-device sync.
-- @return actions list: { {op="insert"|"delete"|"update", ts=..., content=..., meta=...?}, ... }
function Marker.diff(existing_segments, current_highlights, current_meta_map)
    current_meta_map = current_meta_map or {}

    local existing_ts = {}
    for _, seg in ipairs(existing_segments) do
        if seg.type == "hl" then
            existing_ts[seg.ts] = seg.content
        end
    end

    local actions = {}

    -- Inserts: in current but not in existing
    for ts, content in pairs(current_highlights) do
        if existing_ts[ts] == nil then
            local action = { op = "insert", ts = ts, content = content }
            if current_meta_map[ts] then action.meta = current_meta_map[ts] end
            table.insert(actions, action)
        end
    end

    -- Deletes and updates: in existing, check against current
    for _, seg in ipairs(existing_segments) do
        if seg.type == "hl" then
            if current_highlights[seg.ts] == nil then
                table.insert(actions, { op = "delete", ts = seg.ts })
            elseif current_highlights[seg.ts] ~= seg.content then
                -- M7: update carries meta — prefer new (from current_meta_map)
                -- if user re-rendered, else preserve existing seg.meta.
                local action = { op = "update", ts = seg.ts, content = current_highlights[seg.ts] }
                action.meta = current_meta_map[seg.ts] or seg.meta
                table.insert(actions, action)
            end
        end
    end

    return actions
end

--- Find the index in segments where a new HL@ block with given ts should be inserted.
-- Strategy:
--   1. If any HL@ block has ts > new_ts, insert before the first such block.
--   2. Otherwise, append at the end of the file (after all USER content).
local function findInsertionPoint(segments, new_ts)
    for idx, seg in ipairs(segments) do
        if seg.type == "hl" and seg.ts > new_ts then
            return idx
        end
    end
    
    return #segments + 1
end

--- Apply diff actions to existing segments, returning new segments.
-- Order: in-place delete/update first, then sorted inserts.
function Marker.applyDiff(existing_segments, actions)
    local by_ts = {}
    for _, a in ipairs(actions) do
        by_ts[a.ts] = a
    end

    -- Step 1: walk existing segments, apply update in-place, drop deletes.
    local after_inplace = {}
    for _, seg in ipairs(existing_segments) do
        if seg.type == "hl" and by_ts[seg.ts] ~= nil then
            local a = by_ts[seg.ts]
            if a.op == "delete" then
                logger.info("[FNS] deleting HL@ block ts=" .. tostring(seg.ts))
            elseif a.op == "update" then
                logger.info("[FNS] updating HL@ block ts=" .. tostring(seg.ts))
                -- M7: carry action.meta (from current_meta_map or preserved seg.meta)
                -- so pos0/pos1/chapter round-trip through update. Match parse()
                -- pattern: only attach meta when non-nil to keep old notes clean.
                local new_seg = { type = "hl", ts = seg.ts, content = a.content }
                if a.meta then new_seg.meta = a.meta end
                table.insert(after_inplace, new_seg)
            end
            -- "insert" should never target an existing ts; skip silently.
        else
            table.insert(after_inplace, seg)
        end
    end

    -- Step 2: collect inserts and sort by ts ascending (oldest first)
    local inserts = {}
    for _, a in ipairs(actions) do
        if a.op == "insert" then
            table.insert(inserts, a)
        end
    end
    table.sort(inserts, function(a, b) return a.ts < b.ts end)

    -- Step 3: insert each at the right position. Note: positions shift as we
    -- insert, but findInsertionPoint is called fresh each time so it sees
    -- the updated list.
    for _, ins in ipairs(inserts) do
        local pos = findInsertionPoint(after_inplace, ins.ts)
        logger.info("[FNS] inserting HL@ block ts=" .. tostring(ins.ts) .. " at position " .. pos)
        -- M7: carry ins.meta (from current_meta_map) so newly inserted HL@ blocks
        -- ship with pos0/pos1/chapter for cross-device re-creation.
        local new_seg = { type = "hl", ts = ins.ts, content = ins.content }
        if ins.meta then new_seg.meta = ins.meta end
        table.insert(after_inplace, pos, new_seg)
    end

    return after_inplace
end

return Marker
