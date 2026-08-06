--[[--
Three-way merge for FNS bidirectional sync.

Computes actions to apply to both server and local based on three ts sets:
- server_set: ts of HL@ blocks currently in the Obsidian note
- local_set: ts of annotations currently in KOreader
- last_set: ts that existed at the time of last successful sync (per-book snapshot)

Truth table (X = the highlight with this ts exists in the set):

| server | local | last | decision                                              |
|--------|-------|------|-------------------------------------------------------|
|   X    |   X   |  X   | preserve (no action)                                  |
|   X    |   X   |  -   | preserve (first sync, both have; safe default)        |
|   X    |   -   |  X   | delete_on_server (user removed locally)               |
|   X    |   -   |  -   | insert_on_local  (another device created)             |
|   -    |   X   |  X   | delete_on_local  (another device removed)             |
|   -    |   X   |  -   | insert_on_server (local new)                          |
|   -    |   -   |  X   | impossible (corrupt last; skip silently)              |

Public API:
  Threeway.computeActions(server_set, local_set, last_set) -> actions

actions structure:
  {
    insert_on_server = { ts1, ts2, ... }             -- ts to add to server note
    delete_on_server = { ts1, ts2, ... }             -- ts to remove from server note
    insert_on_local  = { ts1, ts2, ... }             -- ts to addItem to local annotations
    delete_on_local  = { ts1, ts2, ... }             -- ts to removeItem from local annotations
  }

Note: meta (pos0/pos1/chapter) is filled by the caller when applying actions,
since it lives in server_segments[idx].meta (for insert_on_local) or
local_annotations[idx] (for insert_on_server). The action only carries ts.

@module fns_sync.threeway
--]]--

local Threeway = {}

--- Compute three-way merge actions from three ts sets.
-- All inputs are hash tables: { [ts_string] = true }.
-- Returns actions table (see module doc).
function Threeway.computeActions(server_set, local_set, last_set)
    server_set = server_set or {}
    local_set = local_set or {}
    last_set = last_set or {}

    local actions = {
        insert_on_server = {},
        delete_on_server = {},
        insert_on_local = {},
        delete_on_local = {},
    }

    -- Collect all unique ts across the three sets.
    local all_ts = {}
    for ts in pairs(server_set) do all_ts[ts] = true end
    for ts in pairs(local_set) do all_ts[ts] = true end
    for ts in pairs(last_set) do all_ts[ts] = true end

    for ts in pairs(all_ts) do
        local in_server = server_set[ts] == true
        local in_local = local_set[ts] == true
        local in_last = last_set[ts] == true

        if in_server and in_local then
            -- Both have it: preserve regardless of last state.
            -- (Three-way have: no-op. First sync both-have: safe default is preserve.)
        elseif in_server and not in_local then
            if in_last then
                -- Server has, local doesn't, last had: user removed locally.
                table.insert(actions.delete_on_server, ts)
            else
                -- Server has, local doesn't, last didn't: another device created.
                table.insert(actions.insert_on_local, ts)
            end
        elseif not in_server and in_local then
            if in_last then
                -- Server doesn't, local has, last had: another device removed.
                table.insert(actions.delete_on_local, ts)
            else
                -- Server doesn't, local has, last didn't: local new.
                table.insert(actions.insert_on_server, ts)
            end
        else
            -- Not in server, not in local, but in last: impossible / corrupt last.
            -- Skip silently. Logged by caller if needed.
        end
    end

    return actions
end

--- Count total actions (useful for debug logs and toast messages).
function Threeway.countActions(actions)
    return #actions.insert_on_server
         + #actions.delete_on_server
         + #actions.insert_on_local
         + #actions.delete_on_local
end

--- Validate actions structure (used by tests and defensive checks).
function Threeway.validateActions(actions)
    if type(actions) ~= "table" then return false end
    for _, key in ipairs({"insert_on_server", "delete_on_server", "insert_on_local", "delete_on_local"}) do
        if type(actions[key]) ~= "table" then return false end
    end
    return true
end

return Threeway
