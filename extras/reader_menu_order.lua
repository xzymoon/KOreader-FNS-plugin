-- Optional: pins "AI 读书助手" (AI Reading Assistant) to the TOP of the
-- tools tab. Generated from KOReader v2026.07.2's built-in
-- frontend/ui/elements/reader_menu_order.lua.
--
-- Install: copy to <KINDLE>:/koreader/settings/reader_menu_order.lua
-- (restart KOReader). Without it, the AI entry simply appears at the END
-- of the tools tab — everything still works.
--
-- After a KOReader OTA upgrade that changes the tools tab, re-generate
-- this file from the new built-in list (built-in changes would be
-- shadowed, not lost — new items fall back to the tab's end).
return {
    tools = {
        "fns_ai",
        "read_timer",
        "calibre",
        "exporter",
        "statistics",
        "progress_sync",
        "cloudstorage",
        "move_to_archive",
        "wallabag",
        "news_downloader",
        "text_editor",
        "profiles",
        "qrclipboard",
        "----------------------------",
        "more_tools",
    },
}
