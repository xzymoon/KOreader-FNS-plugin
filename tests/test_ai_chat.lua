--[[--
Unit tests for M8 ai.lua timeout wiring, max_tokens default, and
finish_reason=length handling.

Background (2026-08-15 Kindle diagnosis): deepseek-v4-flash is a
reasoning model. Two failure modes on Kindle:
  1. wantread after exactly 10s — ai.lua used hardcoded
     Config.AI_HTTP_TIMEOUTS {10, 60}, ignoring settings.ai_timeout_sec.
  2. "AI 回复为空" — hidden reasoning spent all max_tokens (1024)
     before content was written; response has content="",
     finish_reason="length" (reproduced from PC with max_tokens=100).

Run locally (NOT on Kindle) with:
    lua tests/test_ai_chat.lua
--]]--

package.path = package.path .. ";./plugin/fns_sync.koplugin/?.lua"

-- Capture state shared between mocks and assertions
local captured = {
    set_timeout_args = nil,   -- {block, total} last passed to socketutil
    reset_timeout_called = nil,
    request_body = nil,       -- body table last passed to rapidjson.encode
    response_table = nil,     -- table returned by rapidjson.decode
    http_code = 200,          -- code returned by mocked http.request
}

package.preload["gettext"] = function()
    return function(s) return s end
end

package.preload["logger"] = function()
    return { warn = function() end, info = function() end,
             dbg = function() end, err = function() end }
end

package.preload["socket"] = function()
    return {
        -- socket.skip(n, ...) drops the first n return values
        skip = function(n, ...)
            local t = { ... }
            local out = {}
            for i = n + 1, #t do out[#out + 1] = t[i] end
            return unpack(out)
        end,
    }
end

package.preload["socket.http"] = function()
    return {
        request = function(req)
            -- Simulate luasocket request-table form: returns
            -- (1, code, status) and pushes body into the sink.
            if captured.http_code then
                req.sink('{}')
                return 1, captured.http_code, "OK"
            end
            -- Network-error form: code is an error string
            return 1, "wantread", nil
        end,
    }
end

package.preload["ltn12"] = function()
    return {
        sink = {
            table = function(t)
                return function(chunk)
                    if chunk then t[#t + 1] = chunk end
                    return true
                end
            end,
        },
        source = {
            string = function(s)
                local sent = false
                return function()
                    if not sent then sent = true return s end
                    return nil
                end
            end,
        },
    }
end

package.preload["rapidjson"] = function()
    return {
        encode = function(body)
            captured.request_body = body
            return "{}"
        end,
        decode = function(_s)
            return captured.response_table
        end,
    }
end

package.preload["socketutil"] = function()
    return {
        -- ai.lua calls with colon syntax: (self, block, total)
        set_timeout = function(_self, block, total)
            captured.set_timeout_args = { block, total }
        end,
        reset_timeout = function()
            captured.reset_timeout_called = true
        end,
    }
end

local Config = require("config")
local Ai = require("ai")

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

local function reset_captured()
    captured.set_timeout_args = nil
    captured.reset_timeout_called = nil
    captured.request_body = nil
    captured.response_table = nil
    captured.http_code = 200
end

local base_settings = {
    ai_api_base = "https://api.deepseek.com/v1",
    ai_api_key = "sk-test",
}

print("== M8 ai.lua timeout / max_tokens / finish_reason ==")

-- 1. Config defaults raised for reasoning models
check("DEFAULTS.ai_max_tokens == 4096 (reasoning budget)",
    Config.DEFAULTS.ai_max_tokens == 4096)
check("DEFAULTS.ai_timeout_sec == 30", Config.DEFAULTS.ai_timeout_sec == 30)
check("CURRENT_CONFIG_VERSION == 6 (v5→v6 migration bumps max_tokens)",
    Config.CURRENT_CONFIG_VERSION == 6)

-- 2. _rawRequest honors settings.ai_timeout_sec (the 10s wantread bug)
do
    reset_captured()
    local s = { ai_api_base = base_settings.ai_api_base,
                ai_api_key = base_settings.ai_api_key,
                ai_timeout_sec = 30 }
    Ai:_rawRequest(s, { model = "m", messages = {} })
    check("timeout: ai_timeout_sec=30 → set_timeout(30, 120)",
        captured.set_timeout_args[1] == 30 and captured.set_timeout_args[2] == 120)
end

do
    reset_captured()
    local s = { ai_api_base = base_settings.ai_api_base,
                ai_api_key = base_settings.ai_api_key,
                ai_timeout_sec = 60 }
    Ai:_rawRequest(s, { model = "m", messages = {} })
    check("timeout: ai_timeout_sec=60 → set_timeout(60, 240)",
        captured.set_timeout_args[1] == 60 and captured.set_timeout_args[2] == 240)
end

do
    reset_captured()
    local s = { ai_api_base = base_settings.ai_api_base,
                ai_api_key = base_settings.ai_api_key }
    Ai:_rawRequest(s, { model = "m", messages = {} })
    check("timeout: nil ai_timeout_sec → fallback set_timeout(30, 120)",
        captured.set_timeout_args[1] == 30 and captured.set_timeout_args[2] == 120)
end

-- 3. chat: request body max_tokens
do
    reset_captured()
    Ai:chat(base_settings, { { role = "user", content = "hi" } })
    check("chat: request body max_tokens == 4096 (no setting)",
        captured.request_body.max_tokens == 4096)
end

do
    reset_captured()
    local s = { ai_api_base = base_settings.ai_api_base,
                ai_api_key = base_settings.ai_api_key,
                ai_max_tokens = 2048 }
    Ai:chat(s, { { role = "user", content = "hi" } })
    check("chat: explicit ai_max_tokens=2048 honored",
        captured.request_body.max_tokens == 2048)
end

-- 4. chat: empty content with finish_reason=length → actionable message
do
    reset_captured()
    captured.response_table = {
        choices = { {
            finish_reason = "length",
            message = { content = "", reasoning_content = "thinking..." },
        } },
    }
    local r = Ai:chat(base_settings, { { role = "user", content = "hi" } })
    check("length-truncation: ok == false", r.ok == false)
    check("length-truncation: message mentions max_tokens",
        r.message ~= nil and r.message:find("max_tokens") ~= nil)
end

-- 5. chat: empty content with finish_reason=stop → generic empty message
do
    reset_captured()
    captured.response_table = {
        choices = { {
            finish_reason = "stop",
            message = { content = "" },
        } },
    }
    local r = Ai:chat(base_settings, { { role = "user", content = "hi" } })
    check("empty-stop: ok == false", r.ok == false)
    check("empty-stop: generic 回复为空 message",
        r.message ~= nil and r.message:find("回复为空") ~= nil
        and r.message:find("max_tokens") == nil)
end

-- 6. chat: normal content → ok
do
    reset_captured()
    captured.response_table = {
        choices = { {
            finish_reason = "stop",
            message = { content = "这是回答" },
        } },
    }
    local r = Ai:chat(base_settings, { { role = "user", content = "hi" } })
    check("normal: ok == true", r.ok == true)
    check("normal: content returned", r.content == "这是回答")
    check("normal: reset_timeout called after request",
        captured.reset_timeout_called == true)
end

-- 7. menu-persisted strings must be coerced to numbers (review MEDIUM-1)
do
    reset_captured()
    local s = { ai_api_base = base_settings.ai_api_base,
                ai_api_key = base_settings.ai_api_key,
                ai_max_tokens = "4096",       -- _editString stores strings
                ai_temperature = "0.7" }
    Ai:chat(s, { { role = "user", content = "hi" } })
    check("coercion: string ai_max_tokens='4096' → number 4096",
        captured.request_body.max_tokens == 4096)
    check("coercion: string ai_temperature='0.7' → number 0.7",
        captured.request_body.temperature == 0.7)
end

-- 8. guard: ai_timeout_sec=0 (stored as number or string) → fallback 30
do
    reset_captured()
    local s = { ai_api_base = base_settings.ai_api_base,
                ai_api_key = base_settings.ai_api_key,
                ai_timeout_sec = 0 }
    Ai:_rawRequest(s, { model = "m", messages = {} })
    check("guard: ai_timeout_sec=0 → set_timeout(30, 120)",
        captured.set_timeout_args[1] == 30 and captured.set_timeout_args[2] == 120)
end

do
    reset_captured()
    local s = { ai_api_base = base_settings.ai_api_base,
                ai_api_key = base_settings.ai_api_key,
                ai_timeout_sec = "0" }
    Ai:_rawRequest(s, { model = "m", messages = {} })
    check("guard: ai_timeout_sec='0' → set_timeout(30, 120)",
        captured.set_timeout_args[1] == 30 and captured.set_timeout_args[2] == 120)
end

-- 9. network error path → network_error=true with status message
do
    reset_captured()
    captured.http_code = nil   -- mock returns error-string form
    local r = Ai:chat(base_settings, { { role = "user", content = "hi" } })
    check("network-error: ok == false", r.ok == false)
    check("network-error: network_error == true", r.network_error == true)
    check("network-error: message mentions status",
        r.message ~= nil and r.message:find("wantread") ~= nil)
    check("network-error: reset_timeout called",
        captured.reset_timeout_called == true)
end

print(("== Tests: %d passed, %d failed =="):format(tests_passed, tests_failed))
os.exit(tests_failed == 0 and 0 or 1)
