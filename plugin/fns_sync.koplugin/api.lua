--[[--
HTTP client for Fast Note Sync (FNS) service.

Wraps KOreader's socket.http + rapidjson + socketutil stack.

FNS response convention (verified from fast-note-sync-service source):
  - All responses use HTTP 200; business status is in the body's `code` field.
  - Success codes: 1 (Success) / 2 (Created) / 3 (Updated) / 4 (Deleted) / 5 / 6.
  - Common error codes we care about:
       305  ErrorInvalidParams            (malformed request)
       307  ErrorNotUserAuthToken         (no token supplied)
       308  ErrorInvalidUserAuthToken     (token invalid)
       310  ErrorTokenExpired
       315  ErrorAuthTokenScopeRestricted (token lacks this vault)
       430  ErrorNoteNotFound
       431  ErrorNoteExist                (createOnly conflict)
       442  ErrorNoMatchFound             (replace failed because find != match)
       443  ErrorInvalidRegex
  - Auth: `Authorization: Bearer <token>` (also accepts `Token:` header or `?token=`).

@module fns_sync.api
--]]--

local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")

local Api = {}

-- FNS business success codes (pkg/code/common.go: NewSuss 1..6).
local SUCCESS_CODES = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }

-- FNS business error codes used by this module.
local BIZ = {
    INVALID_PARAMS        = 305,
    NOT_USER_AUTH_TOKEN   = 307,
    INVALID_USER_TOKEN    = 308,
    TOKEN_EXPIRED         = 310,
    SCOPE_RESTRICTED      = 315,
    NOTE_NOT_FOUND        = 430,
    NOTE_EXIST            = 431,
    NO_MATCH_FOUND        = 442,
    INVALID_REGEX         = 443,
}

--- Build a URL with optional query string.
-- Normalizes base by stripping trailing slashes (user may have entered
-- "https://fns.example.com/" — without this we'd get "//api/...").
-- util.urlEncode preserves A-Z a-z 0-9 - . _ ~ and percent-encodes the rest.
local function buildUrl(base, path, query)
    base = (base or ""):gsub("/+$", "")
    local url = base .. (path or "")
    if query then
        local parts = {}
        for k, v in pairs(query) do
            parts[#parts + 1] = util.urlEncode(tostring(k)) .. "=" .. util.urlEncode(tostring(v))
        end
        if #parts > 0 then
            url = url .. "?" .. table.concat(parts, "&")
        end
    end
    return url
end

--- Low-level HTTP request (no business-code parsing).
-- Returns raw http_code, body_str, status_line.
function Api:_rawRequest(settings, method, path, body, query)
    local url = buildUrl(settings.server_url, path, query)
    local sink = {}

    local request = {
        url = url,
        method = method,
        sink = ltn12.sink.table(sink),
        headers = {
            ["Authorization"] = "Bearer " .. (settings.api_token or ""),
            ["Accept"] = "application/json",
        },
    }

    if body ~= nil then
        local body_json, err = rapidjson.encode(body)
        if not body_json then
            logger.warn("[FNS] JSON encode failed:", err)
            return nil, "", "json encode failed"
        end
        -- WORKAROUND: KOreader's rapidjson encodes Lua number (double) with a
        -- trailing ".0" for integer values (e.g. 1785730809000.0), which Go's
        -- json.Unmarshal rejects for int64 fields (Ctime/Mtime in
        -- NoteModifyOrCreateRequest), surfacing as FNS code 305 with empty
        -- details. Strip the trailing ".0" when followed by ',' or '}'.
        -- Safe because: (1) string-internal ".0" is always followed by '"',
        -- not ',' or '}'; (2) we only emit integer-valued numbers.
        body_json = body_json:gsub("(%d)%.0([,}])", "%1%2")
        request.source = ltn12.source.string(body_json)
        request.headers["Content-Length"] = #body_json
        request.headers["Content-Type"] = "application/json"
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    -- LuaSocket quirk: http.request returns (1, http_code, ...) on success
    -- but (nil, error_string) on failure. After socket.skip(1, ...), `code`
    -- is the http_code (number) on success, but the error_string on failure
    -- (e.g. "closed", "timeout", "Network is unreachable"). Without this
    -- type check, the error string would be mistaken for an HTTP code by
    -- makeRequest (which only checks `nil`/`0`), surfacing to the user as
    -- garbled "HTTP closed: nil" messages. Normalize: return nil + the
    -- error string as status so makeRequest's existing network_error
    -- branch catches it.
    if type(code) == "string" then
        return nil, table.concat(sink), code
    end

    return code, table.concat(sink), status
end

--- High-level HTTP request: performs the call AND parses FNS business code.
-- @return table {
--   ok            = bool          -- business success (code 1..6)
--   network_error = bool          -- true if socket/DNS/timeout failure
--   http_code     = number|nil
--   biz_code      = number|nil    -- FNS body code field
--   message       = string|nil    -- body message (or status line)
--   data          |any|nil        -- body data field
--   details       = string|nil
-- }
function Api:makeRequest(settings, method, path, body, query)
    local http_code, body_str, status = self:_rawRequest(settings, method, path, body, query)

    -- Network-level failure (timeout / DNS / refused)
    if http_code == nil or http_code == 0 then
        logger.warn("[FNS] " .. method .. " " .. path .. " network error: " .. tostring(status))
        return {
            ok = false,
            network_error = true,
            message = status or _("network unreachable"),
        }
    end

    -- Non-200 HTTP (e.g. reverse-proxy 502/404); body is often HTML, not JSON.
    if http_code ~= 200 then
        logger.warn("[FNS] " .. method .. " " .. path .. " HTTP " .. tostring(http_code) .. ": " .. tostring(status))
        return {
            ok = false,
            http_code = http_code,
            message = string.format("HTTP %s: %s", tostring(http_code), tostring(status)),
        }
    end

    -- Parse FNS response envelope.
    local parsed, _ = rapidjson.decode(body_str)
    if not parsed or parsed.code == nil then
        logger.warn("[FNS] " .. method .. " " .. path .. " non-JSON response: " .. tostring(body_str):sub(1, 200))
        return {
            ok = false,
            http_code = http_code,
            message = _("non-JSON response: ") .. tostring(body_str):sub(1, 200),
        }
    end

    logger.info("[FNS] " .. method .. " " .. path
        .. " biz_code=" .. tostring(parsed.code)
        .. " msg=" .. tostring(parsed.message)
        .. (parsed.details and (" details=" .. tostring(parsed.details)) or ""))
    return {
        ok = SUCCESS_CODES[parsed.code] == true,
        http_code = http_code,
        biz_code = parsed.code,
        status = parsed.status,
        message = parsed.message,
        data = parsed.data,
        details = parsed.details,
    }
end

-- ===========================================================================
-- High-level operations (M2)
-- ===========================================================================

--- Test connection. Verifies server reachability + token validity + vault scope.
-- Uses GET /api/notes?vault=<vault> as a non-mutating probe.
-- (We previously used /api/files?vault=&path=/ but FileListRequest DTO has no
-- `path` field — the param was silently ignored. /api/notes is semantically
-- closer to our use case anyway.)
-- @return {success=bool, message=string, biz_code=number|nil}
function Api:testConnection(settings)
    if not settings.server_url or settings.server_url == "" then
        return { success = false, message = _("FNS 服务 URL 未设置") }
    end
    if not settings.api_token or settings.api_token == "" then
        return { success = false, message = _("API Token 未设置") }
    end
    if not settings.vault or settings.vault == "" then
        return { success = false, message = _("Vault 名未设置") }
    end

    local r = self:makeRequest(settings, "GET", "/api/notes", nil, {
        vault = settings.vault,
    })

    if r.network_error then
        return {
            success = false,
            message = _("网络错误：") .. r.message .. _("（请检查 URL 与网络）"),
        }
    end
    if r.http_code and r.http_code ~= 200 then
        return { success = false, message = r.message }
    end
    if r.ok then
        return {
            success = true,
            biz_code = r.biz_code,
            message = _("连接成功：服务可达，Token 有效，Vault 存在"),
        }
    end

    -- Map known biz codes to friendly hints.
    local hint = {
        [BIZ.NOT_USER_AUTH_TOKEN]   = _("URL 可达，但请求未携带 Token"),
        [BIZ.INVALID_USER_TOKEN]    = _("URL 可达，但 Token 无效"),
        [BIZ.TOKEN_EXPIRED]         = _("URL 可达，但 Token 已过期"),
        [BIZ.SCOPE_RESTRICTED]      = _("URL 可达，但 Token 无权访问该 Vault"),
        [BIZ.INVALID_PARAMS]        = _("URL 可达，但参数错误（Vault 名是否合法？）"),
    }
    return {
        success = false,
        biz_code = r.biz_code,
        message = hint[r.biz_code]
            or string.format(_("FNS 错误 [code=%s]：%s"),
                tostring(r.biz_code), tostring(r.message or "")),
    }
end

--- Read a note. Returns exists flag + content (when present).
-- GET /api/note?vault=&path=
-- @param settings table
-- @param path string note path inside vault (e.g. "KOReader/《三体》读书笔记.md")
-- @return { ok, exists, content, note, biz_code, message, network_error }
function Api:getNote(settings, path)
    local r = self:makeRequest(settings, "GET", "/api/note", nil, {
        vault = settings.vault,
        path = path,
    })

    if r.network_error then
        return { ok = false, network_error = true, message = r.message }
    end
    if r.ok then
        local data = r.data or {}
        return {
            ok = true,
            exists = true,
            content = data.content,
            note = data,
        }
    end
    if r.biz_code == BIZ.NOTE_NOT_FOUND then
        return { ok = true, exists = false }
    end
    return {
        ok = false,
        biz_code = r.biz_code,
        message = r.message,
    }
end

--- Create a new note with createOnly=true (never overwrites existing).
-- POST /api/note
-- @return { ok, created, already_exists, biz_code, message, network_error }
function Api:createNote(settings, path, content)
    local now_ms = os.time() * 1000  -- FNS uses millisecond timestamps
    local r = self:makeRequest(settings, "POST", "/api/note", {
        vault = settings.vault,
        path = path,
        content = content,
        createOnly = true,
        ctime = now_ms,
        mtime = now_ms,
    })

    if r.network_error then
        return { ok = false, network_error = true, message = r.message }
    end
    if r.ok then
        return { ok = true, created = true }
    end
    if r.biz_code == BIZ.NOTE_EXIST then
        return { ok = true, created = false, already_exists = true }
    end
    return {
        ok = false,
        biz_code = r.biz_code,
        message = r.message,
    }
end

--- Overwrite an existing note (used by GET → Lua replace → POST flow).
-- Caller is responsible for content correctness (e.g. preserving marker-outside
-- user edits) and for passing original_ctime so FNS doesn't clobber it
-- (ModifyOrCreate does `note.Ctime = params.Ctime` unconditionally).
-- @param original_ctime number|nil  millisecond timestamp from getNote result
-- @return { ok, biz_code, message, network_error }
function Api:overwriteNote(settings, path, content, original_ctime)
    local now_ms = os.time() * 1000
    local r = self:makeRequest(settings, "POST", "/api/note", {
        vault = settings.vault,
        path = path,
        content = content,
        createOnly = false,
        ctime = original_ctime or now_ms,
        mtime = now_ms,
    })

    if r.network_error then
        return { ok = false, network_error = true, message = r.message }
    end
    if r.ok then
        return { ok = true }
    end
    return {
        ok = false,
        biz_code = r.biz_code,
        message = r.message,
    }
end

--- Find/replace inside a note. Used for marker-based precise insertion.
-- POST /api/note/replace
-- @param opts table { regex=bool, all=bool, fail_if_no_match=bool (default true) }
-- @return { ok, match_count, not_found, no_match, biz_code, message, network_error }
function Api:replaceNote(settings, path, find, replace, opts)
    opts = opts or {}
    local r = self:makeRequest(settings, "POST", "/api/note/replace", {
        vault = settings.vault,
        path = path,
        find = find,
        replace = replace,
        regex = opts.regex == true,
        all = opts.all == true,
        -- Default fail_if_no_match=true so missing marker surfaces as a
        -- recoverable error (caller can fall back to append or recreate).
        failIfNoMatch = opts.fail_if_no_match ~= false,
    })

    if r.network_error then
        return { ok = false, network_error = true, message = r.message }
    end
    if r.ok then
        local match_count = 0
        if type(r.data) == "table" then
            match_count = r.data.matchCount or 0
        end
        return { ok = true, match_count = match_count }
    end

    local out = { ok = false, biz_code = r.biz_code, message = r.message }
    if r.biz_code == BIZ.NOTE_NOT_FOUND then
        out.not_found = true
    elseif r.biz_code == BIZ.NO_MATCH_FOUND then
        out.no_match = true
    elseif r.biz_code == BIZ.INVALID_REGEX then
        out.invalid_regex = true
    end
    return out
end

return Api
