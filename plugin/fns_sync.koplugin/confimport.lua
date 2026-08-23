--[[--
fns_sync.conf — desktop-side configuration import (M10, plan §十一).

Users edit ONE plain-text file on a PC (USB mass storage) instead of
fighting the Kindle virtual keyboard or hand-editing settings.reader.lua
(300+ lines of Lua syntax — the ai_enabled=false incident, 2026-08-23).

File: <koreader>/settings/fns_sync.conf
Format: one `key = value` per line; `#` comments; no quotes/commas.
Values are typed by the DEFAULTS entry for that key (never guessed from
content — a vault literally named "123" stays a string).

Import model (all decided in 3rd-round review, plan §十一 v2):
  - PARTIAL import: only keys present in the conf are overwritten.
  - Content fingerprint guards the file: unchanged content is NOT
    re-imported, so menu-side edits are never clobbered by a stale conf.
    Fingerprint is computed over NORMALIZED content (BOM/CRLF stripped)
    so Windows line-ending churn doesn't re-trigger imports.
  - Template ships fully commented-out AND its fingerprint is recorded
    on generation — double protection against example values leaking in.
  - Whitelist: DEFAULTS scalar keys only (no tables; no multi-line
    default strings like note_template — a one-line conf value would
    destroy a multi-line template).
  - Whole import wrapped in pcall: a corrupt file warns and keeps old
    settings (mirrors KOReader's own defaults.custom.lua pattern).

No G_reader_settings access here — the caller (main.lua init) owns the
fingerprint key fns_sync_conf_hash (top-level, so onResetConfig's table
replacement can't wipe it).
--]]--

local logger = require("logger")
local Config = require("config")

local ConfImport = {}

local function get_settings_dir()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir()
end

local function conf_path()
    return get_settings_dir() .. "/fns_sync.conf"
end

--- Strip UTF-8 BOM and normalize every line ending to \n.
local function normalize(content)
    content = content:gsub("^\xEF\xBB\xBF", "")
    content = content:gsub("\r\n", "\n")
    return content:gsub("\r", "\n")
end

--- djb2 + length — not cryptographic, only change detection.
local function content_hash(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x-%d", h, #s)
end

--- Is `key` importable? Scalar DEFAULTS keys only: tables are out (no
--- one-line representation), and string defaults containing newlines are
--- out (note_template/excerpt_template would be truncated by a one-line
--- conf value).
local function should_import(key)
    local d = Config.DEFAULTS[key]
    if d == nil then return false end
    if type(d) == "table" then return false end
    if type(d) == "string" and d:find("\n", 1, true) then return false end
    return true
end

--- Coerce raw conf text to the DEFAULTS-typed value for `key`.
-- Returns value, err: err non-nil means "skip this key, warn" (bad bool
-- text, non-numeric text for a number key). Empty raw value on a string
--- key is a deliberate CLEAR ("").
local function convert_value(key, raw)
    local d = Config.DEFAULTS[key]
    if type(d) == "boolean" then
        if raw == "true" then return true end
        if raw == "false" then return false end
        return nil, "boolean key expects true/false, got '" .. raw .. "'"
    elseif type(d) == "number" then
        local n = tonumber(raw)
        if n then return n end
        return nil, "number key got non-numeric '" .. raw .. "'"
    end
    return raw
end

--- Parse normalized conf text into { key = value } (typed) plus warnings.
local function parse(content)
    local out, warnings = {}, {}
    local seen = {}
    local line_no = 0
    for line in content:gmatch("[^\n]+") do
        line_no = line_no + 1
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
            local eq = trimmed:find("=", 1, true)  -- first '=' only (base64 tokens end with ==)
            if not eq then
                warnings[#warnings + 1] = "line " .. line_no .. ": no '=' (" .. trimmed .. ")"
            else
                local key = trimmed:sub(1, eq - 1):match("^%s*(.-)%s*$")
                local raw = trimmed:sub(eq + 1):match("^%s*(.-)%s*$")
                if key == "" then
                    warnings[#warnings + 1] = "line " .. line_no .. ": empty key"
                elseif not should_import(key) then
                    if Config.DEFAULTS[key] == nil then
                        warnings[#warnings + 1] = "unknown key '" .. key .. "'"
                    else
                        warnings[#warnings + 1] = "key '" .. key .. "' not importable via conf (table/multi-line)"
                    end
                else
                    local value, err = convert_value(key, raw)
                    if err then
                        warnings[#warnings + 1] = "key '" .. key .. "': " .. err
                    else
                        if seen[key] then
                            warnings[#warnings + 1] = "duplicate key '" .. key .. "' (last wins)"
                        end
                        seen[key] = true
                        out[key] = value
                    end
                end
            end
        end
    end
    return out, warnings
end

-- Sensitive keys whose imported values must not be logged in clear.
local SECRET_KEYS = { api_token = true, ai_api_key = true }

local TEMPLATE = table.concat({
    "# FNS Sync 插件配置（电脑端编辑，保存为 UTF-8 无 BOM）",
    "# 用法：去掉对应行的行首 # 并填入你的值；修改后重启 KOReader 生效。",
    "# 只写你关心的键——没写的键保持 KOReader 里的现有设置不变。",
    "",
    "# ── 模式开关（true=FNS 服务器模式；false=离线本地笔记模式）──",
    "#enabled = false",
    "",
    "# ── FNS 服务器（仅 FNS 模式需要；离线模式忽略）──",
    "#server_url = https://fns.example.com",
    "#api_token = your-token-here",
    "#vault = your-vault-name",
    "",
    "# ── AI 读书助手 ──",
    "#ai_enabled = true",
    "#ai_api_base = https://api.deepseek.com",
    "#ai_api_key = sk-xxxxxxxxxxxxxxxxxxxxxxxx",
    "#ai_model = deepseek-chat",
    "",
    "# ── 本地笔记（仅离线模式；位于 Kindle 根目录下）──",
    "#local_notes_root = FNS-Notes/",
    "",
}, "\n")

--- Default file IO (injectable for tests via opts.read_fn/opts.write_fn).
local function default_read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function default_write(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end

--- Main entry, called from init between migration (main.lua:199) and the
--- backfill save (main.lua:202). Returns a result table for the caller:
---   { hash, imported, warnings, template_created, error }
--- The caller persists `hash` to G_reader_settings["fns_sync_conf_hash"]
--- (top-level key — survives onResetConfig's table replacement).
function ConfImport.checkAndImport(settings, stored_hash, opts)
    opts = opts or {}
    local read_fn = opts.read_fn or default_read
    local write_fn = opts.write_fn or default_write
    local path = opts.path or conf_path()

    local content = read_fn(path)
    if content == nil then
        -- No conf yet: create the (fully commented) template and record
        -- its fingerprint so commented example values can never import.
        local ok = write_fn(path, TEMPLATE)
        if not ok then
            logger.warn("[FNS] conf: template write failed at " .. path)
            return { error = "template_write_failed" }
        end
        return {
            hash = content_hash(normalize(TEMPLATE)),
            imported = {},
            warnings = {},
            template_created = true,
        }
    end

    local norm = normalize(content)
    local hash = content_hash(norm)
    if hash == stored_hash then
        return { hash = hash, imported = {}, warnings = {} }
    end

    -- Corrupt file must not kill init: pcall, warn, keep old settings
    -- (defaults.custom.lua pattern, KOReader luadefaults.lua).
    local ok, parsed, warnings = pcall(parse, norm)
    if not ok then
        logger.warn("[FNS] conf: parse crashed (" .. tostring(parsed) .. "), keeping old settings")
        -- Still record the hash: the file content is unchanged until the
        -- user edits it again, and re-parsing identical bytes would fail
        -- identically — no point retrying every boot.
        return { hash = hash, imported = {}, warnings = { "parse crashed" } }
    end
    warnings = warnings or {}

    local imported = {}
    for k, v in pairs(parsed) do
        settings[k] = v
        imported[#imported + 1] = k
    end
    table.sort(imported)
    for _, w in ipairs(warnings) do
        logger.warn("[FNS] conf: " .. w)
    end
    for _, k in ipairs(imported) do
        if SECRET_KEYS[k] then
            logger.info(string.format("[FNS] conf: imported %s = <masked, %d chars>", k, #tostring(settings[k])))
        else
            logger.info("[FNS] conf: imported " .. k .. " = " .. tostring(settings[k]))
        end
    end
    return { hash = hash, imported = imported, warnings = warnings }
end

-- Exposed for unit tests.
ConfImport._normalize = normalize
ConfImport._content_hash = content_hash
ConfImport._parse = parse
ConfImport._should_import = should_import
ConfImport._convert_value = convert_value
ConfImport._TEMPLATE = TEMPLATE

return ConfImport
