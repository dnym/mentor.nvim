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
    vim.notify(
      n > 0 and ("mentor.nvim: cancelled " .. n .. " operation(s)") or "mentor.nvim: nothing to cancel",
      n > 0 and vim.log.levels.INFO or vim.log.levels.DEBUG
    )
  end, { desc = "Cancel running Mentor operations" })

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
    desc = "Propose a bounded edit for a visual selection or the insertion point (preview, then accept/reject)",
    nargs = "+",
    range = true,
  })

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
