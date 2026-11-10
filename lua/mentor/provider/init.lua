-- Provider interface and capability configuration.
-- The full request/response normalization lands in Milestone 3; this module
-- owns configuration resolution, configured-ness checks, and actionable
-- capability errors.

local config = require("mentor.config")

local M = {}

---@param mode "observer"|"coach"|"implement"
---@return table merged provider settings
function M.settings(mode)
  return config.provider_for(mode)
end

---A mode is usable when endpoint and model are configured.
---@param mode "observer"|"coach"|"implement"
function M.is_configured(mode)
  if config.get().dev.fake_provider then
    return true
  end
  local p = M.settings(mode)
  return p.endpoint ~= "" and p.model ~= ""
end

---Actionable error when a mode is not usable, or nil.
---@param mode "observer"|"coach"|"implement"
---@return string|nil
function M.missing(mode)
  if config.get().dev.fake_provider then
    return nil
  end
  local p = M.settings(mode)
  if p.endpoint == "" then
    return string.format(
      "mentor.nvim: no provider endpoint configured for %s mode. Set providers.default.endpoint or providers.%s.endpoint, or enable dev.fake_provider for the offline placeholder.",
      mode,
      mode
    )
  end
  if p.model == "" then
    return string.format(
      "mentor.nvim: no model configured for %s mode. Set providers.default.model or providers.%s.model.",
      mode,
      mode
    )
  end
  if not p.capabilities.tools then
    return string.format(
      "mentor.nvim: %s mode is configured without native tool calling, which the MVP workflows require. Choose a tool-calling model or set providers.%s.capabilities.tools = true.",
      mode,
      mode
    )
  end
  return nil
end

---Redacted description for status and health output: never include credentials.
---@param mode "observer"|"coach"|"implement"
function M.describe(mode)
  local p = M.settings(mode)
  if config.get().dev.fake_provider then
    return "fake (dev.fake_provider)"
  end
  if p.endpoint == "" or p.model == "" then
    return "not configured"
  end
  return string.format(
    "%s @ %s (tools=%s, streaming=%s)",
    p.model,
    p.endpoint,
    tostring(p.capabilities.tools),
    tostring(p.capabilities.streaming)
  )
end

return M
