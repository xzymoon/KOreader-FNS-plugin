--[[--
Unit tests for M9 localstore.lua (local mode storage backend).

Run locally (NOT on Kindle) with:
    lua tests/test_localstore.lua

KOReader modules are mocked via package.preload. File IO is real: a temp
directory stands in for the device home folder, so getNote/createNote/
overwriteNote/markUploaded are exercised against the actual filesystem.

NOTE on file names: IO cases use ASCII names on purpose. On this Windows
dev box LuaJIT passes raw string bytes to ANSI io.open/os.execute, so a
UTF-8 CJK name in this (UTF-8) source file turns into mojibake under the
system GBK code page. Kindle is a Linux/UTF-8 byte-transparent environment
where CJK names work (verified by real-device tests); CJK path LOGIC is
still covered here via the pure-string _absPath cases below.
--]]--

package.path = package.path .. ";./plugin/fns_sync.koplugin/?.lua"

local is_windows = package.config:sub(1, 1) == "\\"

-- Temp home dir (upvalue so mocks read the current value)
local HOME = os.getenv("TEMP") or "/tmp"
HOME = HOME .. "/fns_localstore_test_" .. tostring(os.time())

local function mkdir_p(path)
    if is_windows then
        os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>NUL')
    else
        os.execute('mkdir -p "' .. path .. '"')
    end
    return true
end

local function rmtree(path)
    if is_windows then
        os.execute('rmdir /s /q "' .. path:gsub("/", "\\") .. '" 2>NUL')
    else
        os.execute('rm -rf "' .. path .. '"')
    end
end

package.preload["gettext"] = function()
    return function(s) return s end
end

package.preload["logger"] = function()
    return {
        warn = function() end,
        info = function() end,
        dbg = function() end,
        err = function() end,
    }
end

-- util.makePath stand-in: real mkdir -p via shell (KOReader's makePath is
-- itself only a mkdir -p wrapper; its internals are KOReader's test duty).
package.preload["util"] = function()
    return { makePath = mkdir_p }
end

-- lfs stand-in: file existence probe only. io.open on a directory fails on
-- Windows, so directories report nil — acceptable: LocalStore queries
-- attributes only on note file paths, directory creation goes through the
-- mocked util.makePath.
package.preload["libs/libkoreader-lfs"] = function()
    local M = {}
    function M.attributes(path, field)
        local f = io.open(path, "r")
        if not f then return nil end
        f:close()
        if field == "mode" then return "file" end
        return { mode = "file", modification = os.time() }
    end
    return M
end

package.preload["apps/filemanager/filemanagerutil"] = function()
    return { getHomeFolder = function() return HOME end }
end

local LocalStore = require("localstore")

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

-- settings without local_notes_root → DEFAULTS "FNS-Notes/" applies
local settings = {}
local rel_path = "KOReader/santi_notes.md"  -- ASCII: see header note

mkdir_p(HOME)

print("== M9 localstore ==")

-- 1. getNote on missing file → { ok = true, exists = false }
do
    local r = LocalStore:getNote(settings, rel_path)
    check("getNote missing: ok", r.ok == true)
    check("getNote missing: exists=false", r.exists == false)
    check("getNote missing: no content key", r.content == nil)
end

-- 2. _absPath: home + default root + rel path, CJK passthrough (pure string)
do
    local cjk = "KOReader/《三体》读书笔记.md"
    local abs = LocalStore._absPath(settings, cjk)
    check("absPath: home prefix", abs:sub(1, #HOME) == HOME)
    check("absPath: default root", abs:find("/FNS%-Notes/") ~= nil)
    check("absPath: CJK rel path appended", abs:find("KOReader/《三体》读书笔记%.md$") ~= nil)
end

-- 3. _absPath: custom root with stray slashes is normalized
do
    local abs = LocalStore._absPath({ local_notes_root = "/MyNotes//" }, "a.md")
    check("absPath: custom root normalized", abs:find("/MyNotes/a%.md$") ~= nil)
end

-- 4. createNote: creates nested dirs + writes content (CJK filename)
do
    local content = "# 三体笔记\n\n<!-- HL@2026-08-22 10:00:00 -->\n高亮\n<!-- /HL@2026-08-22 10:00:00 -->\n"
    local r = LocalStore:createNote(settings, rel_path, content)
    check("createNote: ok", r.ok == true)
    check("createNote: created=true", r.created == true)
    local f = io.open(HOME .. "/FNS-Notes/" .. rel_path, "r")
    check("createNote: file on disk", f ~= nil)
    if f then
        check("createNote: content verbatim", f:read("*a") == content)
        f:close()
    end
end

-- 5. getNote on existing file → content + note.ctime
do
    local r = LocalStore:getNote(settings, rel_path)
    check("getNote existing: ok", r.ok == true)
    check("getNote existing: exists=true", r.exists == true)
    check("getNote existing: content round-trip", r.content ~= nil and r.content:find("三体笔记") ~= nil)
    check("getNote existing: note.ctime number", type(r.note and r.note.ctime) == "number")
end

-- 6. createNote on existing file → already_exists (createOnly semantics)
do
    local r = LocalStore:createNote(settings, rel_path, "should not overwrite")
    check("createNote existing: not ok", r.ok == false)
    check("createNote existing: already_exists=true", r.already_exists == true)
    local r2 = LocalStore:getNote(settings, rel_path)
    check("createNote existing: original preserved", r2.content:find("should not overwrite") == nil)
end

-- 7. overwriteNote: replaces content
do
    local r = LocalStore:overwriteNote(settings, rel_path, "v2 内容", nil)
    check("overwriteNote: ok", r.ok == true)
    local r2 = LocalStore:getNote(settings, rel_path)
    check("overwriteNote: content updated", r2.content == "v2 内容")
end

-- 8. overwriteNote: rebuilds a wiped root directory
do
    rmtree(HOME .. "/FNS-Notes")
    local r = LocalStore:overwriteNote(settings, rel_path, "v3 内容", nil)
    check("overwriteNote wiped dir: ok", r.ok == true)
    local r2 = LocalStore:getNote(settings, rel_path)
    check("overwriteNote wiped dir: content", r2.exists == true and r2.content == "v3 内容")
end

-- 9. markUploaded: renames to .uploaded.bak
do
    local abs = HOME .. "/FNS-Notes/" .. rel_path
    local r = LocalStore:markUploaded(settings, rel_path)
    check("markUploaded: ok", r == true)
    local f = io.open(abs, "r")
    check("markUploaded: original gone", f == nil)
    if f then f:close() end
    local f2 = io.open(abs .. ".uploaded.bak", "r")
    check("markUploaded: .bak exists with content", f2 ~= nil)
    if f2 then
        check("markUploaded: content preserved", f2:read("*a") == "v3 内容")
        f2:close()
    end
end

-- 10. markUploaded: missing file → no-op true
do
    local r = LocalStore:markUploaded(settings, "KOReader/不存在.md")
    check("markUploaded missing: true", r == true)
end

-- 11. Result-shape compatibility with Api consumers (legacy pipeline):
-- ok/exists/content/note.ctime for getNote; ok for overwriteNote;
-- ok/created/already_exists for createNote — all asserted above; here just
-- confirm failures carry local_error=true + message (for _showSyncError).
do
    LocalStore:createNote(settings, rel_path, "recreated")  -- case 9 renamed the original away
    local r = LocalStore:createNote(settings, rel_path, "x")
    check("failure shape: local_error flag",
        r.ok == false and r.already_exists == true and r.local_error == true and type(r.message) == "string")
end

print(string.format("== %d passed, %d failed ==", tests_passed, tests_failed))
rmtree(HOME)
os.exit(tests_failed == 0 and 0 or 1)
