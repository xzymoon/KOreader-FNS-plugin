--[[--
M9 local mode storage backend.

File-based drop-in replacement for the subset of Api used by
_doSyncCurrentBookLegacy: getNote / overwriteNote / createNote. Signature
and result-shape compatible with api.lua so the legacy sync pipeline runs
unmodified (store injection).

Local notes live at:
    <home>/<local_notes_root>/<resolvePath relative path>
- <home> = filemanagerutil.getHomeFolder() — KOReader's user-visible
  partition (e.g. /mnt/us on Kindle), so users can copy notes off the
  device over USB.
- Relative path is the SAME resolvePath result the FNS server would use,
  marker format included — so a local note can seed the first FNS upload
  verbatim (design D4).
--]]--

local logger = require("logger")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")

local Config = require("config")

local LocalStore = {}

--- Absolute path of a note in the local store.
-- filemanagerutil is required lazily at call sites: frontend/apps modules
-- add a load-order dependency plugins avoid at require time (same pattern
-- as bookshortcuts.koplugin).
local function absPath(settings, path)
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local home = filemanagerutil.getHomeFolder()
    local root = settings.local_notes_root or Config.DEFAULTS.local_notes_root
    root = (root:gsub("^/+", ""):gsub("/+$", ""))
    return home .. "/" .. root .. "/" .. path
end

LocalStore._absPath = absPath  -- exposed for tests

--- Read a local note. Result compatible with Api:getNote.
function LocalStore:getNote(settings, path)
    local abs = absPath(settings, path)
    local mode = lfs.attributes(abs, "mode")
    if mode == nil then
        return { ok = true, exists = false }
    end
    if mode ~= "file" then
        -- e.g. a directory sits at the note path
        return { ok = false, local_error = true, message = "not a file: " .. abs }
    end
    local f = io.open(abs, "r")
    if not f then
        return { ok = false, local_error = true, message = "cannot open: " .. abs }
    end
    local content = f:read("*a")
    f:close()
    local attrs = lfs.attributes(abs)
    return {
        ok = true,
        exists = true,
        content = content,
        note = { ctime = (attrs and attrs.modification) or os.time() },
    }
end

--- Create a local note. createOnly semantics, mirrors Api:createNote
--- (never overwrites an existing file).
function LocalStore:createNote(settings, path, content)
    local abs = absPath(settings, path)
    if lfs.attributes(abs, "mode") ~= nil then
        return { ok = false, already_exists = true, local_error = true,
                 message = "local note exists: " .. abs }
    end
    local dir = abs:match("^(.*)/[^/]+$")
    local ok, err = util.makePath(dir)
    if not ok then
        return { ok = false, local_error = true, message = tostring(err) }
    end
    local f = io.open(abs, "w")
    if not f then
        return { ok = false, local_error = true, message = "cannot write: " .. abs }
    end
    f:write(content)
    f:close()
    return { ok = true, created = true }
end

--- Overwrite a local note. V1 ignores the optimistic-lock ctime (design
--- G4): single-client, single-device; external concurrent edits are out of
--- scope. Recreates a wiped FNS-Notes/ directory instead of failing.
function LocalStore:overwriteNote(settings, path, content, original_ctime)
    local abs = absPath(settings, path)
    local f = io.open(abs, "w")
    if not f then
        local dir = abs:match("^(.*)/[^/]+$")
        local ok, err = util.makePath(dir)
        if not ok then
            return { ok = false, local_error = true, message = tostring(err) }
        end
        f = io.open(abs, "w")
        if not f then
            return { ok = false, local_error = true, message = "cannot write: " .. abs }
        end
    end
    f:write(content)
    f:close()
    return { ok = true }
end

--- M9 G3: rename an uploaded seed note to <name>.uploaded.bak after the
--- first successful FNS upload, so FNS-Notes/ keeps no stale "looks-live"
--- copy. Never deletes user content.
function LocalStore:markUploaded(settings, path)
    local abs = absPath(settings, path)
    if lfs.attributes(abs, "mode") == nil then
        return true  -- nothing to rename
    end
    local ok, err = os.rename(abs, abs .. ".uploaded.bak")
    if not ok then
        logger.warn("[FNS] M9 seed rename failed: " .. tostring(err))
        return false
    end
    return true
end

return LocalStore
