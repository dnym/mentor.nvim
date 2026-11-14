-- :checkhealth mentor — version, dependencies, configuration, providers.
-- Errors are actionable (7.4): each names the concrete fix.

local M = {}

---Report whether a mode sends an API key. The key itself is never shown.
---@param mode string
---@param key {state: string, var: string, remote: boolean}
function M.report_key(mode, key)
  if key.state == "set" then
    vim.health.ok(mode .. " API key: found in $" .. key.var)
  elseif key.state == "disabled" then
    vim.health.info(mode .. " API key: none (api_key_env is empty); requests are sent without one")
  else
    local msg = string.format(
      "%s API key: $%s is not set, so requests are sent without one. "
        .. "Export it before starting Neovim if your provider needs a key, "
        .. 'or set api_key_env = "" for this provider to silence this.',
      mode,
      key.var
    )
    if key.remote then
      vim.health.warn(msg)
    else
      vim.health.info(msg)
    end
  end
end

function M.check()
  vim.health.start("mentor.nvim")

  if vim.fn.has("nvim-0.12.6") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()) .. " meets the v0.12.6 baseline")
  else
    vim.health.error(
      "Neovim "
        .. tostring(vim.version())
        .. " is below the supported baseline v0.12.6; upgrade (e.g. pacman -S neovim)"
    )
  end

  local config = require("mentor.config")
  local errors = config.errors()
  if #errors > 0 then
    for _, err in ipairs(errors) do
      vim.health.error(err)
    end
  else
    vim.health.ok("configuration valid")
  end

  local transport = require("mentor.provider.transport")
  local transport_err = transport.check()
  if transport_err then
    vim.health.error(transport_err)
  else
    vim.health.ok("transport executable: curl")
  end

  local storage_ok, storage = pcall(require, "mentor.storage")
  if storage_ok then
    vim.health.ok("sqlite available via FFI: " .. storage.sqlite_version())
  else
    vim.health.error(
      "sqlite3 could not be loaded via LuaJIT FFI ("
        .. tostring(storage)
        .. "); on Arch install the sqlite package (pacman -S sqlite)"
    )
  end

  if vim.fn.executable("git") == 1 then
    vim.health.ok("git available (optional: git history/diff tools degrade gracefully without it)")
  else
    vim.health.warn("git not found; project roots fall back to configured/working directories")
  end

  local provider = require("mentor.provider")
  for _, mode in ipairs({ "coach", "observer", "implement" }) do
    local missing = provider.missing(mode)
    if missing then
      vim.health.warn(missing)
    else
      vim.health.ok(mode .. " provider: " .. provider.describe(mode))
      M.report_key(mode, provider.key_status(mode))
    end
  end

  if config.get().dev.fake_provider then
    vim.health.info("dev.fake_provider is enabled: no network requests will be made")
  end
end

return M
