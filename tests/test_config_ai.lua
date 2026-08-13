--[[--
Unit tests for M8 AI config defaults.

Run locally (NOT on Kindle) with:
    lua tests/test_config_ai.lua
--]]--

-- Mock gettext module before requiring config
package.preload["gettext"] = function()
    return {
        -- Mock gettext functions (identity function for tests)
        gettext = function(text) return text end,
        ngettext = function(singular, plural, n) return n == 1 and singular or plural end,
    }
end

package.path = package.path .. ";./plugin/fns_sync.koplugin/?.lua"

local Config = require("config")

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

print("== M8 AI config defaults ==")

-- Schema version bumped
check("CURRENT_CONFIG_VERSION == 5", Config.CURRENT_CONFIG_VERSION == 5)

-- All AI fields exist in DEFAULTS with correct defaults
check("DEFAULTS.ai_enabled == false", Config.DEFAULTS.ai_enabled == false)
check("DEFAULTS.ai_api_base exists", Config.DEFAULTS.ai_api_base ~= nil)
check("DEFAULTS.ai_api_key == '' (empty by default)", Config.DEFAULTS.ai_api_key == "")
check("DEFAULTS.ai_model exists", Config.DEFAULTS.ai_model ~= nil)
check("DEFAULTS.ai_system_prompt exists", Config.DEFAULTS.ai_system_prompt ~= nil)
check("DEFAULTS.ai_max_tokens == 1024", Config.DEFAULTS.ai_max_tokens == 1024)
check("DEFAULTS.ai_temperature == 0.7", Config.DEFAULTS.ai_temperature == 0.7)
check("DEFAULTS.ai_timeout_sec == 30", Config.DEFAULTS.ai_timeout_sec == 30)

-- Quick prompt templates
check("DEFAULTS.ai_quick_prompts is table", type(Config.DEFAULTS.ai_quick_prompts) == "table")
check("DEFAULTS.ai_quick_prompts.translate exists", Config.DEFAULTS.ai_quick_prompts.translate ~= nil)
check("DEFAULTS.ai_quick_prompts.explain exists", Config.DEFAULTS.ai_quick_prompts.explain ~= nil)
check("DEFAULTS.ai_quick_prompts.comment exists", Config.DEFAULTS.ai_quick_prompts.comment ~= nil)
check("DEFAULTS.ai_quick_prompts.summarize exists", Config.DEFAULTS.ai_quick_prompts.summarize ~= nil)

-- HTTP timeout constants for AI calls
check("Config.AI_HTTP_TIMEOUTS is table", type(Config.AI_HTTP_TIMEOUTS) == "table")
check("Config.AI_HTTP_TIMEOUTS[1] == 10 (block)", Config.AI_HTTP_TIMEOUTS[1] == 10)
check("Config.AI_HTTP_TIMEOUTS[2] == 60 (total)", Config.AI_HTTP_TIMEOUTS[2] == 60)

print(("== Tests: %d passed, %d failed =="):format(tests_passed, tests_failed))
os.exit(tests_failed == 0 and 0 or 1)
