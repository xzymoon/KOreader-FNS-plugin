--[[--
Default configuration and constants for FNS Sync plugin.

All values can be overridden by user via the settings menu
(written into G_reader_settings["fns_sync"]).

@module fns_sync.config
--]]--

local _ = require("gettext")

local Config = {}

-- Schema version for settings persistence. Bump whenever a default value
-- changes incompatibly (e.g. a template is restructured, a field is renamed).
-- main.lua:init checks this against the version stored in G_reader_settings
-- and runs the corresponding migration block when an older version is found.
Config.CURRENT_CONFIG_VERSION = 4

-- Single excerpt render template (rendered once per highlight, then wrapped
-- in an HL@ block by excerpt.lua:renderExcerptBlock).
-- Placeholders (filled in excerpt.lua at sync time):
--   {page}      real page number (annotation.pageno)
--   {text}      highlighted text
--   {note}      user's note block (rendered as "**笔记**：..." or empty)
--   {chapter}   chapter title
--   {datetime}  annotation.datetime (no longer emitted in default template —
--               the HL@ block markers already carry the datetime)
--   {color}     highlight color (or its emoji if color_to_emoji is on)
--
-- Design choices (M4 + v3):
--   - Page marker uses 「📖 第 N 页」 instead of `[p.N]` — the latter is
--     parsed as a wiki-link by Obsidian.
--   - Page number on its own line, body quote on following lines. Multi-line
--     {text} gets a `> ` prefix per line in excerpt.lua so the whole excerpt
--     stays inside one Markdown blockquote.
--   - No trailing timestamp — HL@ block head/tail markers (<!-- HL@ts --> /
--     <!-- /HL@ts -->) already show the datetime, so a body timestamp was
--     redundant. Users who want it back can use a custom {datetime}.
Config.DEFAULT_EXCERPT_TEMPLATE = [[
> 📖 第 {page} 页
> {text}

{note}
]]

-- Default note template used when creating a new note file.
-- {{VALUE:xxx}} placeholders are filled by KOreader when available;
-- others are left intact for the user to fill via Obsidian Templater/QuickAdd.
-- {{HIGHLIGHTS}} is replaced at sync time with all HL@ blocks concatenated
-- (each block is wrapped by marker.lua, see marker.lua for format).
Config.DEFAULT_NOTE_TEMPLATE = [[# 📖 《 {{VALUE:书名}} 》读书笔记

## 📌 书籍信息
- **书名**：《 {{VALUE:书名}} 》
- **作者**： {{VALUE:作者}}
- **出版社**： {{VALUE:出版社}}
- **出版年份**： {{VALUE:年份}}
- **阅读状态**: 在读/读完/待整理
- **阅读开始**: {{VALUE:阅读开始}}
- **阅读结束**:
- **评分**: ⭐⭐⭐⭐⭐
---



# 摘录 ：

{{HIGHLIGHTS}}
]]

-- Default highlight color → emoji map (M5: verify against actual KOreader colors)
Config.DEFAULT_COLOR_EMOJI_MAP = {
    yellow = "🟡",
    green  = "🟢",
    blue   = "🔵",
    red    = "🔴",
    purple = "🟣",
    orange = "🟠",
}

-- M6: Offline queue constants.

-- Max consecutive failures before a queue entry is "frozen" (no longer
-- auto-retried; user must manually retry or clear from the queue menu).
Config.MAX_RETRY_ATTEMPTS = 5

-- M7 Day 3 review (security-reviewer H-1/H-2): bounds to defend against
-- attacker-controlled vault content. Real-world references:
--   - MAX_NOTE_BYTES: typical Obsidian note < 100 KB; 1 MB is generous cap
--     that catches pathologically large or malicious notes without
--     blocking legitimate use.
--   - MAX_XPOINTER_LEN: real KOreader XPointers are < 200 chars (crengine
--     DOM path). 256 is generous; reject longer to prevent resource abuse.
--   - MAX_CHAPTER_LEN: chapter titles are typically < 50 chars; 256 is a
--     safety net against metadata.lua injection.
Config.MAX_NOTE_BYTES    = 1024 * 1024  -- 1 MB
Config.MAX_XPOINTER_LEN  = 256
Config.MAX_CHAPTER_LEN   = 256

-- FNS business codes indicating token failure. When _processQueueItem sees
-- any of these in the result, it immediately freezes ALL queue entries and
-- shows a one-shot toast prompting the user to re-enter the token (HIGH-I fix).
Config.TOKEN_INVALID_CODES = { [307] = true, [308] = true }

-- All user-adjustable settings with their defaults.
Config.DEFAULTS = {
    -- Master switch
    enabled = false,

    -- Service connection
    server_url = "",        -- e.g. "https://fns.example.com"
    api_token  = "",
    vault      = "",

    -- Note organization
    note_path_prefix         = "KOReader/",
    note_filename_template   = "《{title}》读书笔记.md",
    note_template            = Config.DEFAULT_NOTE_TEMPLATE,

    -- Per-book title/author overrides.
    -- Keyed by absolute file path of the book (self.ui.document.file).
    -- Each value is { title = "...", author = "..." }; fields are optional.
    -- Empty string clears the field (falls back to doc_props).
    -- Use case: anthology books where the file name is long but the user is
    -- reading only one sub-book; user can override title to the sub-book name.
    book_overrides           = {},

    -- Excerpt rendering
    show_page_number     = true,
    show_note_marker     = true,
    show_chapter_subtitle = true,
    color_to_emoji       = false,
    excerpt_template     = Config.DEFAULT_EXCERPT_TEMPLATE,
    color_emoji_map      = Config.DEFAULT_COLOR_EMOJI_MAP,

    -- Auto-sync (M5). Master switch gates the per-event sub-switches below.
    -- All sub-switches additionally require `enabled` AND isConfigured().
    -- Highlight path is debounced; close-document path fires immediately
    -- after cancelling any pending debounce timer. Both paths silent-skip
    -- when offline (no WiFi prompt) — KOreader already persists highlights
    -- to local metadata.lua, so data is never lost; next open/close/manual
    -- sync will catch up.
    auto_sync_enabled   = true,
    sync_on_highlight   = true,
    sync_on_book_close  = true,
    debounce_seconds    = 5,

    -- M7: Bidirectional sync (cross-device pull via three-way merge).
    -- All three sub-switches additionally require `enabled` AND isConfigured()
    -- AND auto_sync_enabled (bidirectional piggybacks on the M5 dispatcher).
    --
    -- bidirectional_sync_enabled: master gate. When true, _triggerSync routes
    -- to _doSyncCurrentBookBidirectional (three-way merge with pull); when
    -- false/nil, routes to _doSyncCurrentBookLegacy (M5/M6 push-only).
    -- First-time enable pops a privacy confirmation dialog (see main.lua
    -- menu code); bidirectional_first_use_confirmed gates that dialog.
    --
    -- pull_on_book_open: when true, onOpenDocument schedules a 2s-delayed
    -- pull (lets crengine finish loading before HTTP + addItem batch).
    -- Renamed from sync_on_book_open (M5 placeholder, never wired).
    --
    -- PRIVACY NOTE: bidirectional sync writes per-highlight XPointer
    -- coordinates into the Obsidian note (so other devices can recreate
    -- highlights at the correct position). If the vault is shared/public/
    -- compromised, an attacker can infer reading progress and book structure
    -- from these coordinates. The first-use dialog calls this out.
    bidirectional_sync_enabled        = false,
    pull_on_book_open                 = false,
    bidirectional_first_use_confirmed = false,

    -- M6: Offline queue. When enabled, highlights created while offline are
    -- persisted to G_reader_settings["fns_sync_queue"] (keyed by book path)
    -- and auto-retried when NetworkConnected fires. When disabled, falls back
    -- to M5 behavior (silent skip, catch up on next open/close/manual).
    --
    -- PRIVACY NOTE: fns_sync_queue stores book path + title (PII). KOreader
    -- has no per-key backup exclusion, so this data is included if the user
    -- exports/backups the global settings.lua. Don't put tokens or secrets
    -- in the queue.
    --
    -- M7 NOTE: queue path (M6) always uses Legacy push-only — even when
    -- bidirectional_sync_enabled is true. Rationale: queued books are by
    -- definition offline (queue fires on NetworkConnected), so pull has
    -- nothing to fetch that's newer than local; and addItem requires the
    -- book to be open (rare case for a queued book). See user decision #4
    -- in progress 2026-08-06.
    offline_queue_enabled = true,
}

return Config
