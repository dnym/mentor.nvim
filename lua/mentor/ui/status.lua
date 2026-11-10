-- Activity, configuration, and actionable failure display.
-- Renders into a native scratch buffer; usage accounting appears with the
-- Milestone 3 provider loop.

local M = {}

local STATUS_NAME = "mentor://status"

local function collect_lines()
  local config = require("mentor.config")
  local project = require("mentor.project")
  local provider = require("mentor.provider")
  local transport = require("mentor.provider.transport")
  local chat = require("mentor.ui.chat")

  local lines = { "# Mentor.nvim status", "" }

  local errors = config.errors()
  if #errors > 0 then
    lines[#lines + 1] = "Configuration errors:"
    for _, err in ipairs(errors) do
      lines[#lines + 1] = "  ! " .. err
    end
  else
    lines[#lines + 1] = "Configuration: valid"
  end

  local proj = project.current()
  if proj then
    lines[#lines + 1] =
      string.format("Project: %s (%s)", proj.identity, proj.is_git and "git" or "non-git root")
  else
    lines[#lines + 1] = "Project: none activated yet"
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Providers:"
  for _, mode in ipairs({ "coach", "observer", "implement" }) do
    lines[#lines + 1] = string.format("  %-9s %s", mode, provider.describe(mode))
  end

  local transport_err = transport.check()
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Transport: "
    .. (transport_err and ("unavailable - " .. transport_err) or "curl subprocess (ready)")

  local storage_ok, storage_mod = pcall(require, "mentor.storage")
  if storage_ok then
    lines[#lines + 1] = "Storage: sqlite "
      .. storage_mod.sqlite_version()
      .. " via FFI, data dir "
      .. config.get().data_dir
  else
    lines[#lines + 1] = "Storage: sqlite3 unavailable via FFI - run :checkhealth mentor"
  end

  local active = chat.active_count()
  lines[#lines + 1] = "Active operations: "
    .. (active > 0 and tostring(active) .. " (Ctrl-C safe; :MentorStop cancels)" or "none")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Milestone 1 shell: Coach runs against the fake provider when dev.fake_provider is set."
  lines[#lines + 1] = "Observer, memory, budgets, and the provider loop arrive in later milestones."
  return lines
end

function M.open()
  local buf = vim.fn.bufnr(STATUS_NAME)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, STATUS_NAME)
  else
    vim.bo[buf].modifiable = true
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, collect_lines())
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "mentortext"

  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
  else
    vim.api.nvim_set_current_win(win)
  end
end

return M
