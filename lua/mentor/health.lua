-- :checkhealth mentor — version, dependencies, configuration, providers.
-- Errors are actionable (7.4): each names the concrete fix.

local M = {}

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
    end
  end

  if config.get().dev.fake_provider then
    vim.health.info("dev.fake_provider is enabled: no network requests will be made")
  end
end

return M
