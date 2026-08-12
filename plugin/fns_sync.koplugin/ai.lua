--[[--
HTTP client for AI chat completions (DeepSeek / OpenAI-compatible).

Wraps KOreader's socket.http + rapidjson + socketutil stack — same pattern
as api.lua (synchronous call wrapped in UIManager:nextTick by the caller).

API spec: POST {base_url}/chat/completions
  Headers: Authorization: Bearer <api_key>, Content-Type: application/json
  Body:    { model, messages, max_tokens, temperature, stream=false }
  Response: 200 { choices: [{ message: { content: "..." } }], ... }

@module fns_sync.ai
--]]--

local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")

local Config = require("config")

local Ai = {}

--- Low-level HTTP POST to {base_url}/chat/completions.
-- Mirrors api.lua:_rawRequest structure but targets OpenAI-compatible
-- endpoint with Bearer auth. No business-code envelope (OpenAI uses HTTP
-- status only); caller parses response via rapidjson directly.
--
-- @param settings table  plugin settings (ai_api_base, ai_api_key)
-- @param body table      request body table (model, messages, ...)
-- @return http_code, body_str, status  (same convention as api.lua)
function Ai:_rawRequest(settings, body)
    -- Normalize base URL: strip trailing slashes (same as api.lua:buildUrl)
    local base = (settings.ai_api_base or ""):gsub("/+$", "")
    local url = base .. "/chat/completions"

    local body_json, err = rapidjson.encode(body)
    if not body_json then
        logger.warn("[FNS-AI] JSON encode failed:", err)
        return nil, "", "json encode failed"
    end
    -- Reuse api.lua's rapidjson .0 workaround (api.lua:92-99). OpenAI
    -- body fields are all string or number; max_tokens/temperature are
    -- number so could theoretically get ".0" — strip defensively.
    body_json = body_json:gsub("(%d)%.0([,}])", "%1%2")

    local sink = {}
    local request = {
        url = url,
        method = "POST",
        sink = ltn12.sink.table(sink),
        source = ltn12.source.string(body_json),
        headers = {
            ["Authorization"] = "Bearer " .. (settings.ai_api_key or ""),
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Content-Length"] = #body_json,
        },
    }

    socketutil:set_timeout(Config.AI_HTTP_TIMEOUTS[1], Config.AI_HTTP_TIMEOUTS[2])
    local code, _, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    -- Normalize network-error case (api.lua:118-122): when http.request
    -- fails, the returned "code" is actually the error string ("timeout",
    -- "closed", "Network is unreachable"). Without this check Ai:chat
    -- would mistake the string for HTTP code.
    if type(code) == "string" then
        return nil, table.concat(sink), code
    end

    return code, table.concat(sink), status
end

--- Send a chat completion request to the configured AI service.
--
-- @param settings table       plugin settings (ai_api_base, ai_api_key,
--                             ai_model, ai_max_tokens, ai_temperature)
-- @param messages table|array conversation history, each entry:
--                             { role = "system"|"user"|"assistant",
--                               content = "..." }
-- @return table {
--   ok            = bool      -- got a valid response with content
--   network_error = bool      -- socket/DNS/timeout failure
--   http_code     = number|nil
--   content       = string|nil -- AI's reply text (choices[1].message.content)
--   raw           = string|nil -- raw response body (for error diagnosis)
--   message       = string|nil -- user-facing error description (Chinese)
-- }
function Ai:chat(settings, messages)
    if not settings.ai_api_base or settings.ai_api_base == "" then
        return { ok = false, message = _("AI 服务 URL 未设置（菜单 → FNS 同步 → AI 助手 → API 设置）") }
    end
    if not settings.ai_api_key or settings.ai_api_key == "" then
        return { ok = false, message = _("AI API Key 未设置") }
    end

    local body = {
        model = settings.ai_model or "deepseek-chat",
        messages = messages,
        max_tokens = settings.ai_max_tokens or 1024,
        temperature = settings.ai_temperature or 0.7,
        stream = false,
    }

    logger.info("[FNS-AI] POST /chat/completions model=" .. tostring(body.model)
        .. " messages=" .. #messages .. " max_tokens=" .. tostring(body.max_tokens))

    local http_code, body_str, status = self:_rawRequest(settings, body)

    -- Network failure
    if http_code == nil or http_code == 0 then
        logger.warn("[FNS-AI] network error: " .. tostring(status))
        return {
            ok = false,
            network_error = true,
            message = _("网络错误：") .. tostring(status) .. _("（请检查网络与 API URL）"),
        }
    end

    -- Non-200 HTTP
    if http_code ~= 200 then
        logger.warn("[FNS-AI] HTTP " .. tostring(http_code) .. ": " .. tostring(body_str):sub(1, 200))
        local hint
        if http_code == 401 then
            hint = _("AI API Key 无效（401）")
        elseif http_code == 429 then
            hint = _("请求太频繁，请 30 秒后再试（429 限流）")
        elseif http_code >= 500 then
            hint = _("AI 服务异常（5xx），请稍后再试")
        else
            hint = string.format(_("AI 服务返回 HTTP %s"), tostring(http_code))
        end
        return {
            ok = false,
            http_code = http_code,
            raw = body_str,
            message = hint,
        }
    end

    -- Parse JSON response
    local parsed, perr = rapidjson.decode(body_str)
    if not parsed then
        logger.warn("[FNS-AI] JSON parse failed: " .. tostring(perr) .. " body: " .. tostring(body_str):sub(1, 200))
        return {
            ok = false,
            http_code = http_code,
            raw = body_str,
            message = _("AI 回复解析失败（详见 crash.log）"),
        }
    end

    -- Extract content
    local choices = parsed.choices
    if type(choices) ~= "table" or #choices == 0 then
        logger.warn("[FNS-AI] no choices in response: " .. tostring(body_str):sub(1, 200))
        return {
            ok = false,
            http_code = http_code,
            raw = body_str,
            message = _("AI 回复格式异常（无 choices）"),
        }
    end
    local content = choices[1].message and choices[1].message.content
    if not content or content == "" then
        logger.warn("[FNS-AI] empty content in response: " .. tostring(body_str):sub(1, 200))
        return {
            ok = false,
            http_code = http_code,
            raw = body_str,
            message = _("AI 回复为空"),
        }
    end

    logger.info("[FNS-AI] success: " .. tostring(#content) .. " chars")
    return {
        ok = true,
        http_code = http_code,
        content = content,
    }
end

return Ai
