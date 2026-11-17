-- Activity, configuration, and actionable failure display.
-- Renders into a native scratch buffer.

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

  local implement_mod = require("mentor.implement")
  local observer_mod = require("mentor.observer")
  local obs_activity = observer_mod.activity()
  local active = chat.active_count()
    + require("mentor.memory.consolidate").active_count()
    + implement_mod.active_count()
    + (obs_activity.running and 1 or 0)
  lines[#lines + 1] = "Active operations: "
    .. (active > 0 and tostring(active) .. " (Ctrl-C safe; :MentorStop cancels)" or "none")
  if obs_activity.running then
    lines[#lines + 1] = "Observer: background investigation running for " .. obs_activity.running
  end
  if #obs_activity.pending > 0 then
    table.sort(obs_activity.pending)
    lines[#lines + 1] = "Observer: pending pass(es) for " .. table.concat(obs_activity.pending, ", ")
  end
  local queued = chat.queued_count()
  if queued > 0 then
    lines[#lines + 1] = "Queued requests: " .. tostring(queued)
  end
  local pending = implement_mod.pending_count()
  if pending > 0 then
    lines[#lines + 1] = "Implement: "
      .. pending
      .. " pending proposal(s) — :MentorImplementReview, then accept or reject"
  end

  local records_mod = require("mentor.storage.records")
  if proj and records_mod.projects.get(proj.identity) then
    local row_id = records_mod.projects.get(proj.identity).id
    local totals = records_mod.usage.totals(row_id, records_mod.usage.today(), "interactive")
    lines[#lines + 1] = "Usage today (interactive, this project): "
      .. totals.model_requests
      .. " requests, ~"
      .. totals.est_tokens
      .. " est tokens"
      .. (totals.reported_input + totals.reported_output > 0 and (" (provider reported " .. totals.reported_input .. "/" .. totals.reported_output .. ")") or "")
      .. (totals.open_reservations > 0 and (" (" .. totals.open_reservations .. " in flight)") or "")
    local btotals = records_mod.usage.totals(row_id, records_mod.usage.today(), "background")
    lines[#lines + 1] = "Usage today (background, this project): "
      .. btotals.model_requests
      .. " requests, ~"
      .. btotals.est_tokens
      .. " est tokens"
      .. (btotals.reported_input + btotals.reported_output > 0 and (" (provider reported " .. btotals.reported_input .. "/" .. btotals.reported_output .. ")") or "")
      .. (btotals.open_reservations > 0 and (" (" .. btotals.open_reservations .. " in flight)") or "")
    local snap = observer_mod.status_snapshot(proj) or { enabled = false }
    lines[#lines + 1] = "Observer: "
      .. (snap.enabled and (snap.paused and "paused (this session only)" or "on") or "off")
      .. (snap.running and "; pass running" or "")
      .. (snap.pending and "; pass pending" or "")
      .. " — :MentorObserve"
    if snap.last_error then
      lines[#lines + 1] = "Observer last issue: " .. snap.last_error
    end
    local oc = records_mod.observations.counts(row_id)
    if oc.active + oc.dismissed > 0 then
      lines[#lines + 1] = "Observations: "
        .. oc.active
        .. " active"
        .. (oc.stale > 0 and (" (" .. oc.stale .. " stale)") or "")
        .. (oc.dismissed > 0 and (", " .. oc.dismissed .. " dismissed") or "")
        .. (oc.useful + oc.not_useful > 0 and ("; rated " .. oc.useful .. " useful / " .. oc.not_useful .. " not useful") or "")
        .. " — :MentorObservations"
    end
    local memory_mod = require("mentor.memory")
    local mc = memory_mod.counts(proj)
    lines[#lines + 1] = "Memory: "
      .. mc.global
      .. " global, "
      .. mc.project
      .. " project entries"
      .. (mc.protected > 0 and (" (" .. mc.protected .. " user-protected)") or "")
      .. (mc.deleted > 0 and ("; " .. mc.deleted .. " deleted (reversible)") or "")
      .. " — :MentorMemory"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Coach runs the bounded tool-calling loop against the configured provider"
  lines[#lines + 1] = "(or the offline fake provider when dev.fake_provider is set)."
  lines[#lines + 1] = "Implement proposes one bounded buffer edit at a time; nothing applies without"
  lines[#lines + 1] = "an explicit :MentorImplementAccept."
  lines[#lines + 1] = "Automatic observation is off for every project until :MentorObserve enable (it"
  lines[#lines + 1] = "transmits change digests, including unsaved code, to the Observer provider)."
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
