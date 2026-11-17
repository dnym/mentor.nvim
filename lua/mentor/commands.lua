-- Command registration only; requires are deferred to invocation so plugin
-- loading stays cheap and performs no I/O or network work. No default
-- keymaps are imposed.

local M = {}

local registered = false

local function notify_error(err)
  vim.notify(err, vim.log.levels.ERROR)
end

function M.register()
  if registered then
    return
  end
  registered = true

  vim.api.nvim_create_user_command("MentorChat", function()
    local _, err = require("mentor.ui.chat").open()
    if err then
      notify_error(err)
    end
  end, { desc = "Open the Coach conversation for the current project" })

  vim.api.nvim_create_user_command("MentorChatAsk", function(opts)
    local _, err = require("mentor.ui.chat").ask(opts.args)
    if err then
      notify_error(err)
    end
  end, { desc = "Ask Coach a question", nargs = "+" })

  vim.api.nvim_create_user_command("MentorStop", function()
    local n = require("mentor.ui.chat").stop()
      + require("mentor.memory.consolidate").stop()
      + require("mentor.implement").stop()
      + require("mentor.observer").stop()
    vim.notify(
      n > 0 and ("mentor.nvim: cancelled " .. n .. " operation(s)") or "mentor.nvim: nothing to cancel",
      n > 0 and vim.log.levels.INFO or vim.log.levels.DEBUG
    )
  end, { desc = "Cancel running Mentor operations" })

  vim.api.nvim_create_user_command("MentorObserve", function(opts)
    local observer = require("mentor.observer")
    local sub = vim.trim(opts.args or "")
    local ok, msg
    if sub == "" then
      local snap = observer.status_snapshot()
      if snap and snap.enabled then
        ok, msg = observer.disable()
      else
        ok, msg = observer.enable()
      end
    elseif sub == "enable" then
      ok, msg = observer.enable()
    elseif sub == "disable" then
      ok, msg = observer.disable()
    elseif sub == "pause" then
      ok, msg = observer.pause()
    elseif sub == "resume" then
      ok, msg = observer.resume()
    elseif sub == "review" then
      ok, msg = observer.review()
    else
      notify_error("mentor.nvim: usage :MentorObserve [enable|disable|pause|resume|review]")
      return
    end
    if not ok and msg then
      notify_error(msg)
    elseif ok and msg then
      vim.notify(msg, vim.log.levels.INFO)
    end
  end, {
    desc = "Toggle or control proactive observation for this project",
    nargs = "?",
    complete = function(arg_lead)
      local out = {}
      for _, s in ipairs({ "enable", "disable", "pause", "resume", "review" }) do
        if s:find("^" .. vim.pesc(arg_lead)) then
          out[#out + 1] = s
        end
      end
      return out
    end,
  })

  vim.api.nvim_create_user_command("MentorObservations", function()
    local _, err = require("mentor.ui.observations").open()
    if err then
      notify_error(err)
    end
  end, { desc = "Open the observation list (dismiss, snooze, mute, rate, explain)" })

  vim.api.nvim_create_user_command("MentorExplain", function(opts)
    local proj = require("mentor.project").ensure_current()
    if not proj then
      notify_error("mentor.nvim: no project context")
      return
    end
    local records_mod = require("mentor.storage.records")
    local row = records_mod.projects.get(proj.identity)
    local id
    local arg = vim.trim(opts.args or "")
    if arg ~= "" then
      id = tonumber((arg:gsub("^o", "")))
    end
    if not id and row then
      local rows = records_mod.observations.list_active(row.id)
      for _, r in ipairs(rows) do
        if r.dismissed == 0 then
          id = r.id
          break
        end
      end
    end
    if not id then
      notify_error("mentor.nvim: no observation to explain (:MentorExplain <id>, see :MentorObservations)")
      return
    end
    local ok, err = require("mentor.ui.observations").explain(proj, id)
    if not ok then
      notify_error(err)
    end
  end, { desc = "Ask Coach to explain an observation (default: newest active)", nargs = "?" })

  vim.api.nvim_create_user_command("MentorImplement", function(opts)
    local _, err = require("mentor.implement").start(opts.args, {
      range = opts.range,
      line1 = opts.line1,
      line2 = opts.line2,
      vmode = vim.fn.visualmode(),
    })
    if err then
      notify_error(err)
    end
  end, {
    desc = "Propose a bounded edit for a visual selection or the insertion point (review, then accept/reject)",
    nargs = "+",
    range = true,
  })

  vim.api.nvim_create_user_command("MentorImplementReview", function(opts)
    local _, err = require("mentor.implement").review(opts.args)
    if err then
      notify_error(err)
    end
  end, { desc = "Review the pending Implement proposal as a diff in its own tab", nargs = "?" })

  vim.api.nvim_create_user_command("MentorImplementLog", function()
    local _, err = require("mentor.implement").open_log()
    if err then
      notify_error(err)
    end
  end, { desc = "Show this project's Implement log (the model's narration and tool activity)" })

  vim.api.nvim_create_user_command("MentorImplementAccept", function(opts)
    local _, err = require("mentor.implement").accept(opts.args)
    if err then
      notify_error(err)
    end
  end, { desc = "Apply the pending Implement proposal (one undo reverts it)", nargs = "?" })

  vim.api.nvim_create_user_command("MentorImplementReject", function(opts)
    local _, err = require("mentor.implement").reject(opts.args)
    if err then
      notify_error(err)
    end
  end, { desc = "Reject the pending Implement proposal (the buffer stays untouched)", nargs = "?" })

  vim.api.nvim_create_user_command("MentorChatClear", function()
    local proj = require("mentor.project").ensure_current()
    if not proj then
      notify_error("mentor.nvim: no project context")
      return
    end
    local n = require("mentor.ui.chat").clear(proj)
    vim.notify(
      n > 0 and ("mentor.nvim: cleared " .. n .. " Coach message(s) for this project")
        or "mentor.nvim: this project's Coach conversation is already empty",
      vim.log.levels.INFO
    )
  end, { desc = "Clear the Coach conversation for the current project" })

  vim.api.nvim_create_user_command("MentorMemory", function(opts)
    require("mentor.ui.memory_commands").run(opts.args or "")
  end, {
    desc = "Inspect and control persistent memory",
    nargs = "?",
    complete = function(arg_lead)
      local subs = {
        "edit",
        "revert",
        "delete",
        "erase",
        "protect",
        "consolidate",
      }
      local out = {}
      for _, s in ipairs(subs) do
        if s:find("^" .. vim.pesc(arg_lead)) then
          out[#out + 1] = s
        end
      end
      return out
    end,
  })

  vim.api.nvim_create_user_command("MentorStatus", function()
    require("mentor.ui.status").open()
  end, { desc = "Show Mentor provider, activity, and storage status" })
end

return M
