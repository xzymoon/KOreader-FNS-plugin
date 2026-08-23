--[[--
Pure gating decisions for FNS Sync plugin (M10).

No KOReader dependencies — designed for unit testing (tests/test_gate.lua).
main.lua keeps thin wrappers (_isLocalMode etc.) around these so the
scenario matrix lives in one auditable place.

M10 semantics: `enabled` is a MODE switch (true = FNS server mode,
false = offline/local mode). Local mode requires no further switches for
manual sync or AI-add-to-note; auto-write is gated by auto_sync_enabled
alone (user's informed opt-in), in BOTH modes.
--]]--

local Gate = {}

--- Mode: enabled=false → local (offline) mode.
function Gate.isLocalMode(settings)
    return not settings.enabled
end

--- Entry check for _triggerSync (manual button, auto-sync, AI add-to-note).
-- Returns (allowed, local_mode, reason):
--   allowed=false + reason="conf_incomplete": FNS mode chosen (enabled=true)
--   but service settings incomplete — caller shows a hint (manual) or logs
--   a skip (auto, silent). NOT silently falling back to local: the user
--   explicitly chose FNS mode.
--   Local mode is always allowed — zero extra switches (M10 design).
function Gate.syncEntry(settings, is_configured)
    local local_mode = Gate.isLocalMode(settings)
    if not local_mode and not is_configured then
        return false, local_mode, "conf_incomplete"
    end
    return true, local_mode, nil
end

--- Gate for auto-sync (highlight-debounced and close-document paths).
-- enabled is deliberately NOT checked: both modes may auto-write
-- (local md or FNS server); auto_sync_enabled is the user's informed
-- opt-in switch. has_open_book is supplied by the caller
-- (self.ui and self.ui.annotation).
function Gate.autoSyncAllowed(settings, has_open_book)
    return settings.auto_sync_enabled == true and has_open_book == true
end

--- Gate for bidirectional pull scheduling (onOpenDocument) and manual pull.
-- Pull is FNS-only by definition: requires FNS mode (enabled=true) plus
-- complete service config. Local mode (enabled=false) must never trigger
-- remote pulls even if bidirectional_sync_enabled is a leftover true
-- from FNS days (M10 review patch §3.6.2).
function Gate.pullAllowed(settings, is_configured)
    return settings.enabled == true and is_configured == true
end

return Gate
