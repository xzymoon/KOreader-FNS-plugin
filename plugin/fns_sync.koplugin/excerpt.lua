--[[--
Render annotations to markdown and resolve note paths.

Entry points used by main.lua sync flow:
  - renderExcerpt(ann, settings)            single annotation -> markdown string
  - renderExcerptBlock(anns, settings)      all annotations -> { ts -> block_content }
  - renderFullNote(highlights_by_ts, settings, meta)
                                            complete note (template + HL@ blocks)
  - resolvePath(settings, meta)             compute final note path with sanitization

M4 change: per-highlight HL@ marker blocks (see marker.lua) replace the old
HIGHLIGHTS_START/END region markers. User text between HL@ blocks is preserved
across syncs.

@module fns_sync.markdown
--]]--

local util = require("util")
local logger = require("logger")
local _ = require("gettext")

local Config = require("config")
local Marker = require("marker")

local Markdown = {}

-- ===========================================================================
-- Helpers
-- ===========================================================================

--- Plain (non-pattern) string substitution.
-- Lua's string.gsub interprets BOTH the pattern and the replacement specially
-- ({ } and % are pattern/meta characters), which corrupts our placeholders.
-- We do manual find+concat instead — same semantics, no surprises.
local function safeReplace(haystack, needle, replacement)
    local out = {}
    local i = 1
    while true do
        local start, finish = string.find(haystack, needle, i, true)  -- plain=true
        if not start then
            table.insert(out, string.sub(haystack, i))
            break
        end
        table.insert(out, string.sub(haystack, i, start - 1))
        table.insert(out, replacement)
        i = finish + 1
    end
    return table.concat(out)
end

-- ===========================================================================
-- Single excerpt rendering
-- =========================================================================--

--- Render one annotation to markdown according to user's settings.
-- @param ann table  {datetime, pageno, text, note, chapter, color, ...}
-- @param settings table
-- @treturn string
function Markdown:renderExcerpt(ann, settings)
    local template = settings.excerpt_template or Config.DEFAULT_EXCERPT_TEMPLATE

    -- {page}: empty when show_page_number is off
    local page_str = ""
    if settings.show_page_number ~= false and ann.pageno ~= nil then
        page_str = tostring(ann.pageno)
    end

    -- {note}: render as "**笔记**：<text>" when note exists AND show_note_marker on;
    -- empty otherwise (M5 may add a "plain" mode later)
    local note_str = ""
    if settings.show_note_marker ~= false and ann.note and ann.note ~= "" then
        note_str = "**笔记**：" .. ann.note
    end

    -- {color}: emoji when color_to_emoji on (and color known), else raw color name
    local color_str = ""
    if ann.color and ann.color ~= "" then
        if settings.color_to_emoji then
            local map = settings.color_emoji_map or Config.DEFAULT_COLOR_EMOJI_MAP
            color_str = map[ann.color] or ann.color
        else
            color_str = ann.color
        end
    end

    -- {text}: prefix every line with "> " so multi-line excerpts (e.g. lists
    -- with "一、二、三、") stay inside the same Markdown blockquote as the
    -- `> 📖 第 N 页` header line. Without this, only the first line gets
    -- the ">" prefix from the template and subsequent lines render outside
    -- the blockquote — visual misalignment.
    local text_str = ann.text or ""
    text_str = text_str:gsub("\n", "\n> ")

    local rendered = template
    rendered = safeReplace(rendered, "{page}",     page_str)
    rendered = safeReplace(rendered, "{text}",     text_str)
    rendered = safeReplace(rendered, "{note}",     note_str)
    rendered = safeReplace(rendered, "{chapter}",  ann.chapter or "")
    rendered = safeReplace(rendered, "{datetime}", ann.datetime or "")
    rendered = safeReplace(rendered, "{color}",    color_str)

    -- Trim trailing newlines so the HL@ close marker sits directly below the
    -- excerpt (no blank line). Leading whitespace is left untouched — the
    -- chapter heading prefix in renderExcerptBlock controls that.
    rendered = rendered:gsub("\n+$", "")

    return rendered
end

-- ===========================================================================
-- Block rendering (per-highlight { ts -> content } table)
-- ===========================================================================

--- Render all annotations into a { datetime -> block_content } table.
-- Sorts by datetime (stable), prepends `## chapter` heading inside each
-- block when show_chapter_subtitle is on AND the chapter differs from the
-- previous annotation's chapter (in datetime order).
--
-- Each block_content is the rendered excerpt (with optional chapter heading
-- prepended). The caller (renderFullNote or marker.lua flow) is responsible
-- for wrapping block_content in HL@ markers.
--
-- @param annotations list  annotation objects from KOreader
-- @param settings table
-- @return table  { [datetime_str] = block_content_str }
function Markdown:renderExcerptBlock(annotations, settings)
    -- Defensive copy + sort (caller may keep using the original table)
    local list = {}
    for _, ann in ipairs(annotations) do
        table.insert(list, ann)
    end
    table.sort(list, function(a, b)
        return (a.datetime or "") < (b.datetime or "")
    end)

    local use_chapter = settings.show_chapter_subtitle ~= false
    local result = {}
    local last_chapter = nil
    local chapter_count = 0

    for _, ann in ipairs(list) do
        local excerpt = self:renderExcerpt(ann, settings)
        if use_chapter and ann.chapter and ann.chapter ~= ""
            and ann.chapter ~= last_chapter then
            -- Increment chapter counter when chapter changes
            chapter_count = chapter_count + 1
            -- Chapter heading directly above the excerpt body, no blank line
            -- in between (visual density requested by users). The excerpt
            -- itself already starts with `> 📖 第 N 页`.
            excerpt = "## " .. chapter_count .. "：" .. ann.chapter .. "\n" .. excerpt
            last_chapter = ann.chapter
        end
        -- Index by datetime; later ann with same datetime would overwrite
        -- (rare in practice — KOreader datetimes are per-highlight unique).
        result[ann.datetime or ""] = excerpt
    end

    logger.info("[FNS] rendered " .. #list .. " annotations to HL@ block table")
    return result
end

-- ===========================================================================
-- Full note rendering (template + HL@ blocks)
-- ===========================================================================

--- Render a brand-new note from the user's note_template.
-- Fills {{VALUE:书名}} / {{VALUE:作者}} / {{VALUE:语言}} from KOreader doc_props.
-- Leaves {{VALUE:出版社}} / {{VALUE:年份}} / {{VALUE:阅读开始}} intact (KOreader
-- has no such fields — user fills via Obsidian Templater/QuickAdd).
-- Replaces the {{HIGHLIGHTS}} placeholder with all HL@ blocks concatenated
-- in datetime order; if no placeholder, appends at end.
--
-- @param highlights_by_ts table  result of renderExcerptBlock
-- @param settings table
-- @param meta table  { title, author, language, ... }
-- @param current_meta_map table|nil  (M7) optional { ts -> { pos0, pos1, chapter } }
--        from local annotations. When present, each HL@ block's open marker
--        carries pos0/pos1/chapter for cross-device re-creation. Legacy path
--        omits this (nil) → blocks have no META fields (back-compat).
-- @return string  complete note content ready to POST
function Markdown:renderFullNote(highlights_by_ts, settings, meta, current_meta_map)
    local template = settings.note_template or Config.DEFAULT_NOTE_TEMPLATE

    local function fill(text, key, value)
        if value == nil or value == "" then
            return text
        end
        return safeReplace(text, "{{VALUE:" .. key .. "}}", tostring(value))
    end

    local rendered = template
    rendered = fill(rendered, "书名", meta.title)
    rendered = fill(rendered, "作者", meta.author)
    rendered = fill(rendered, "语言", meta.language)

    -- Sort datetimes ascending, render each as an HL@ block.
    -- Uses Marker.wrapBlock so the new-note path and the diff path
    -- (Marker.serialize) produce identical block formatting — without
    -- this, the two paths drift (e.g. blank line before close marker)
    -- and users see "first sync wrong, second sync right" symptoms.
    local sorted_ts = {}
    for ts in pairs(highlights_by_ts) do
        table.insert(sorted_ts, ts)
    end
    table.sort(sorted_ts)

    local blocks = {}
    for _, ts in ipairs(sorted_ts) do
        -- M7: pass current_meta_map[ts] (may be nil) so first-time notes
        -- created on a bidirectional-enabled device ship with META fields.
        local block_meta = current_meta_map and current_meta_map[ts]
        table.insert(blocks, Marker.wrapBlock(ts, highlights_by_ts[ts], block_meta))
    end
    local highlights_str = table.concat(blocks, "\n\n\n")  -- two blank lines between blocks (matches serialize)

    -- Replace {{HIGHLIGHTS}} placeholder; if absent, append at end
    if string.find(rendered, "{{HIGHLIGHTS}}", 1, true) then
        rendered = safeReplace(rendered, "{{HIGHLIGHTS}}", highlights_str)
    else
        rendered = rendered .. "\n\n" .. highlights_str .. "\n"
    end

    return rendered
end

-- ===========================================================================
-- Path resolution
-- ===========================================================================

--- Compute the final note path inside the vault.
-- Steps:
--   1. Normalize path separators: backslashes (\) → forward slashes (/)
--      in both prefix and template. Windows users may type "\" out of
--      habit; without normalization, FNS stores the literal "\", Obsidian
--      normalizes it to "/", and the two clients disagree on the note's
--      path key — causing "ghost notes" that survive Obsidian deletes.
--   2. Render note_filename_template with {title}/{author}/{language}/{year}/{date}
--   3. Split on "/", sanitize each segment with util.getSafeFilename
--   4. Filter empty segments AGAIN (defensive: ".." sanitizes to "" — without
--      this, "../etc" would slip through as path traversal)
--   5. Auto-append .md if last segment has no extension
--   6. Prepend note_path_prefix (normalized: strip leading/trailing /)
-- @treturn string e.g. "KOReader/刘慈欣/三体.md"
function Markdown:resolvePath(settings, meta)
    local prefix   = settings.note_path_prefix or ""
    local template = settings.note_filename_template or Config.DEFAULTS.note_filename_template

    -- Normalize separators FIRST, before any split/strip logic runs.
    -- This is the only place backslashes are handled; everywhere downstream
    -- assumes "/"-only paths.
    prefix   = prefix:gsub("\\", "/")
    template = template:gsub("\\", "/")

    -- Render placeholders.
    local rendered = template
    rendered = safeReplace(rendered, "{title}",    meta.title or "")
    rendered = safeReplace(rendered, "{author}",   meta.author or "")
    rendered = safeReplace(rendered, "{language}", meta.language or "")
    rendered = safeReplace(rendered, "{year}",     meta.year or "")  -- KOreader doesn't provide
    rendered = safeReplace(rendered, "{date}",     os.date("%Y-%m-%d"))

    -- Split on "/", sanitize each segment, filter empties twice
    -- (getSafeFilename alone doesn't strip "/" — it would mangle the slash
    --  into an underscore; we also re-check post-sanitize because ".." → "")
    local segments = {}
    for seg in string.gmatch(rendered, "[^/]+") do
        seg = (seg:gsub("^%s+", ""):gsub("%s+$", ""))  -- trim whitespace
        if seg ~= "" then
            local safe = util.getSafeFilename(seg)
            if safe ~= "" then
                table.insert(segments, safe)
            end
        end
    end

    local path = table.concat(segments, "/")
    if path == "" then
        path = "Untitled"  -- extreme edge case (user template rendered to nothing)
    end

    -- Auto-append .md if last segment has no extension.
    -- Lets users write `{title}` instead of `{title}.md` in the template.
    local last_seg = path:match("[^/]+$")
    if last_seg and not last_seg:match("%.") then
        path = path .. ".md"
    end

    -- Normalize prefix: strip leading/trailing slashes, ensure single trailing /
    -- (user may have written "/KOReader/" — we want "KOReader/")
    prefix = prefix:gsub("^/+", ""):gsub("/+$", "")
    if prefix ~= "" then
        path = prefix .. "/" .. path
    end

    logger.info("[FNS] resolved path: " .. path)
    return path
end

return Markdown
