-- Unit: :checkhealth reports whether each mode sends an API key, never the
-- key itself, and only warns where a key is likely required.

local H = require("tests.support.harness")
local config = require("mentor.config")
local provider = require("mentor.provider")
local health = require("mentor.health")

return function()
  local VAR = "MENTOR_TEST_HEALTH_KEY"
  local SECRET = "sk-health-test-value-4f2a"

  ---Run fn with vim.health captured; returns {level = {messages}}.
  local function capture(fn)
    local seen = { ok = {}, info = {}, warn = {}, error = {} }
    local real = vim.health
    vim.health = setmetatable({}, { __index = real })
    for level in pairs(seen) do
      vim.health[level] = function(msg)
        table.insert(seen[level], msg)
      end
    end
    vim.health.start = function() end
    local ok, err = pcall(fn)
    vim.health = real
    if not ok then
      error(err)
    end
    return seen
  end

  local function configure(endpoint, key_env)
    config.load({
      providers = { default = { endpoint = endpoint, model = "m", api_key_env = key_env } },
    })
  end

  local function joined(seen)
    local all = {}
    for _, msgs in pairs(seen) do
      vim.list_extend(all, msgs)
    end
    return table.concat(all, "\n")
  end

  H.test("key status distinguishes set, unset, and disabled without exposing the key", function()
    vim.env[VAR] = SECRET
    configure("https://api.example.test/v1", VAR)
    local status = provider.key_status("coach")
    H.eq(status.state, "set", "key found")
    H.eq(status.remote, true, "https endpoint counts as remote")
    local seen = capture(health.check)
    H.contains_text(table.concat(seen.ok, "\n"), "coach API key: found in $" .. VAR, "reported as ok")
    H.ok(not joined(seen):find(SECRET, 1, true), "the key value never appears in health output")

    vim.env[VAR] = nil
    H.eq(provider.key_status("coach").state, "unset", "missing variable is unset")
    configure("http://127.0.0.1:8080/v1", "")
    H.eq(provider.key_status("coach").state, "disabled", "empty api_key_env disables the key")
    config.load({})
  end)

  H.test("an unset key warns for https endpoints and is only info for local ones", function()
    vim.env[VAR] = nil
    configure("https://api.example.test/v1", VAR)
    local remote = capture(health.check)
    H.contains_text(table.concat(remote.warn, "\n"), "$" .. VAR .. " is not set", "hosted endpoint warns")

    configure("http://127.0.0.1:8080/v1", VAR)
    local local_seen = capture(health.check)
    H.ok(not table.concat(local_seen.warn, "\n"):find("API key", 1, true), "local endpoint does not warn")
    H.contains_text(
      table.concat(local_seen.info, "\n"),
      "$" .. VAR .. " is not set",
      "local endpoint gets info"
    )

    configure("http://127.0.0.1:8080/v1", "")
    local disabled = capture(health.check)
    H.contains_text(table.concat(disabled.info, "\n"), "api_key_env is empty", "disabled key explained")
    config.load({})
  end)
end
