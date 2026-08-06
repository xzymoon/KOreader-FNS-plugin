--[[--
Unit tests for threeway.lua merge algorithm.

Run locally (NOT on Kindle) with:
    lua tests/test_threeway.lua

Requires no external test framework — just Lua 5.1+ (matches KOreader's Lua).
--]]--

-- Make the plugin dir resolvable when running from repo root.
package.path = package.path .. ";./plugin/fns_sync.koplugin/?.lua"

local Threeway = require("threeway")

local tests_passed = 0
local tests_failed = 0

local function check(name, cond)
    if cond then
        tests_passed = tests_passed + 1
        print(("  ✓ %s"):format(name))
    else
        tests_failed = tests_failed + 1
        print(("  ✗ %s FAILED"):format(name))
    end
end

local function set(...)
    local t = {}
    for _, v in ipairs({...}) do t[v] = true end
    return t
end

local function bag_equal(arr1, arr2)
    if #arr1 ~= #arr2 then return false end
    local seen = {}
    for _, v in ipairs(arr1) do seen[v] = (seen[v] or 0) + 1 end
    for _, v in ipairs(arr2) do
        if not seen[v] then return false end
        seen[v] = seen[v] - 1
        if seen[v] < 0 then return false end
    end
    return true
end

print("== Three-way merge truth table ==")

-- All empty (first sync, no data anywhere)
do
    local a = Threeway.computeActions({}, {}, {})
    check("all empty: no actions", Threeway.countActions(a) == 0)
end

-- All three identical -> preserve
do
    local a = Threeway.computeActions(set("t1", "t2"), set("t1", "t2"), set("t1", "t2"))
    check("all three identical: no actions", Threeway.countActions(a) == 0)
end

-- Local new (insert_on_server)
do
    local a = Threeway.computeActions(set("t1"), set("t1", "t2"), set("t1"))
    check("local new: insert_on_server has t2", bag_equal(a.insert_on_server, {"t2"}))
    check("local new: no other actions",
        #a.delete_on_server == 0 and #a.insert_on_local == 0 and #a.delete_on_local == 0)
end

-- Local removed (delete_on_server)
do
    local a = Threeway.computeActions(set("t1", "t2"), set("t1"), set("t1", "t2"))
    check("local removed: delete_on_server has t2", bag_equal(a.delete_on_server, {"t2"}))
    check("local removed: no other actions",
        #a.insert_on_server == 0 and #a.insert_on_local == 0 and #a.delete_on_local == 0)
end

-- Server new (insert_on_local)
do
    local a = Threeway.computeActions(set("t1", "t2"), set("t1"), set("t1"))
    check("server new: insert_on_local has t2", bag_equal(a.insert_on_local, {"t2"}))
    check("server new: no other actions",
        #a.insert_on_server == 0 and #a.delete_on_server == 0 and #a.delete_on_local == 0)
end

-- Server removed (delete_on_local)
do
    local a = Threeway.computeActions(set("t1"), set("t1", "t2"), set("t1", "t2"))
    check("server removed: delete_on_local has t2", bag_equal(a.delete_on_local, {"t2"}))
    check("server removed: no other actions",
        #a.insert_on_server == 0 and #a.delete_on_server == 0 and #a.insert_on_local == 0)
end

-- First sync, both have (last empty) -> preserve (safe default)
do
    local a = Threeway.computeActions(set("t1", "t2"), set("t1", "t2"), {})
    check("first sync both have: no actions", Threeway.countActions(a) == 0)
end

-- Impossible branch: in last only -> skip silently
do
    local a = Threeway.computeActions({}, {}, set("t1"))
    check("impossible branch: skipped silently", Threeway.countActions(a) == 0)
end

-- Mixed real-world scenario: A added t3, B added t4, both started from {t1, t2}
-- Server has {t1, t2, t3, t4} (after B pulled in t3 from A in a prior round)
-- Wait — let's model the actual flow.
-- Round 1: A has {t1, t2, t3}, server has {t1, t2}, last has {t1, t2}
--   A's computeActions:
--     t3: server no, local yes, last no -> insert_on_server (A pushes t3)
--   After A's push: server = {t1, t2, t3}, A.last = {t1, t2, t3}
-- Round 2: B has {t1, t2, t4}, server has {t1, t2, t3}, B.last = {t1, t2}
--   B's computeActions:
--     t3: server yes, local no, last no -> insert_on_local (B pulls t3)
--     t4: server no, local yes, last no -> insert_on_server (B pushes t4)
do
    local a_B = Threeway.computeActions(set("t1", "t2", "t3"), set("t1", "t2", "t4"), set("t1", "t2"))
    check("mixed: B pulls t3", bag_equal(a_B.insert_on_local, {"t3"}))
    check("mixed: B pushes t4", bag_equal(a_B.insert_on_server, {"t4"}))
    check("mixed: no deletes",
        #a_B.delete_on_server == 0 and #a_B.delete_on_local == 0)
end

-- Delete cycle prevention: A deletes t2, B still has t2
-- Server state: {t1, t2} (B's last sync kept t2 alive erroneously? No - A already removed it)
-- Better model:
--   Initial: server={t1,t2}, A.local={t1,t2}, B.local={t1,t2}, last={t1,t2} both
--   A deletes t2: A.local={t1}
--   A syncs: server={t1}, A.last={t1} (or {t1} since t2 no longer in either)
--   Wait — A.last after sync should be server_ts ∪ local_ts = {t1} ∪ {t1} = {t1}
--   B syncs: server={t1}, B.local={t1,t2}, B.last={t1,t2}
--     t2: server no, local yes, last yes -> delete_on_local (B removes t2)
--   NO RESURRECTION CYCLE
do
    local a_B = Threeway.computeActions(set("t1"), set("t1", "t2"), set("t1", "t2"))
    check("delete cycle: B deletes t2 locally", bag_equal(a_B.delete_on_local, {"t2"}))
    check("delete cycle: no insert_on_server (would resurrect)",
        #a_B.insert_on_server == 0)
end

-- nil inputs should not crash
do
    local a = Threeway.computeActions(nil, nil, nil)
    check("nil inputs: no crash, no actions", Threeway.countActions(a) == 0)
    check("nil inputs: validateActions passes", Threeway.validateActions(a))
end

print(("== Tests: %d passed, %d failed =="):format(tests_passed, tests_failed))
os.exit(tests_failed == 0 and 0 or 1)
