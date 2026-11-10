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
    vim.notify(
      n > 0 and ("mentor.nvim: cancelled " .. n .. " operation(s)") or "mentor.nvim: nothing to cancel",
      n > 0 and vim.log.levels.INFO or vim.log.levels.DEBUG
    )
  end, { desc = "Cancel running Mentor operations" })

  vim.api.nvim_create_user_command("MentorStatus", function()
    require("mentor.ui.status").open()
  end, { desc = "Show Mentor provider, activity, and storage status" })
end

return M
