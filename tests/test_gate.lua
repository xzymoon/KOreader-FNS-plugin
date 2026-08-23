--[[--
Unit tests for M10 gate.lua (pure gating decisions).

Run locally with:
    lua tests/test_gate.lua

Covers the M10 scenario matrix (plan §三): enabled is a MODE switch —
local mode (enabled=false) passes sync with zero extra switches; FNS mode
with incomplete config is blocked with "conf_incomplete"; auto-write is
gated by auto_sync_enabled alone in BOTH modes; pull is FNS-only.
--]]--

package.path = package.path .. ";./plugin/fns_sync.koplugin/?.lua"

local Gate = require("gate")

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

print("== M10 gate ==")

-- ── isLocalMode ──
do
    check("isLocalMode: enabled=false → local", Gate.isLocalMode({ enabled = false }) == true)
    check("isLocalMode: enabled=true → FNS", Gate.isLocalMode({ enabled = true }) == false)
end

-- ── syncEntry: the 7-scenario matrix ──
do
    -- 1. offline mode + anything → allowed, local
    local ok, lm = Gate.syncEntry({ enabled = false }, false)
    check("sync: offline (unconfigured) allowed", ok == true)
    check("sync: offline local_mode", lm == true)

    local ok2, lm2 = Gate.syncEntry({ enabled = false }, true)
    check("sync: offline (server configured) still local", ok2 == true and lm2 == true)

    -- 2. FNS mode + configured → allowed, not local
    local ok3, lm3, r3 = Gate.syncEntry({ enabled = true }, true)
    check("sync: FNS+configured allowed", ok3 == true)
    check("sync: FNS mode not local", lm3 == false)
    check("sync: FNS+configured no reason", r3 == nil)

    -- 3. FNS mode + unconfigured → blocked with conf_incomplete
    local ok4, lm4, r4 = Gate.syncEntry({ enabled = true }, false)
    check("sync: FNS+unconfigured blocked", ok4 == false)
    check("sync: FNS+unconfigured reason", r4 == "conf_incomplete")
    check("sync: FNS+unconfigured mode flag still false", lm4 == false)
end

-- ── autoSyncAllowed: no enabled gate in either mode ──
do
    check("auto: enabled=false + auto_sync + book → allowed (M10 core)",
        Gate.autoSyncAllowed({ enabled = false, auto_sync_enabled = true }, true) == true)
    check("auto: enabled=true + auto_sync + book → allowed",
        Gate.autoSyncAllowed({ enabled = true, auto_sync_enabled = true }, true) == true)
    check("auto: auto_sync off → denied",
        Gate.autoSyncAllowed({ enabled = true, auto_sync_enabled = false }, true) == false)
    check("auto: no open book → denied",
        Gate.autoSyncAllowed({ enabled = false, auto_sync_enabled = true }, false) == false)
    check("auto: auto_sync nil → denied (explicit true required)",
        Gate.autoSyncAllowed({ enabled = false }, true) == false)
end

-- ── pullAllowed: FNS-only ──
do
    check("pull: FNS+configured → allowed",
        Gate.pullAllowed({ enabled = true }, true) == true)
    -- M10 §3.6.2: leftover bidirectional in local mode must NOT pull
    check("pull: local mode (enabled=false) + configured → denied",
        Gate.pullAllowed({ enabled = false }, true) == false)
    check("pull: FNS + unconfigured → denied",
        Gate.pullAllowed({ enabled = true }, false) == false)
    check("pull: local + unconfigured → denied",
        Gate.pullAllowed({ enabled = false }, false) == false)
end

print(("%s passed, %s failed"):format(tests_passed, tests_failed))
os.exit(tests_failed == 0 and 0 or 1)
