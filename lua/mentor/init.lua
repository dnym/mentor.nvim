-- Public setup and entry points. Loading this module performs no network
-- I/O; provider traffic requires explicit user requests in later milestones.

local M = {}

local augroup = "mentor"

local autocmds_defined = false

local function define_autocmds()
  if autocmds_defined then
    return
  end
  autocmds_defined = true
  vim.api.nvim_create_augroup(augroup, { clear = true })
  -- Project focus tracks the active normal buffer. Plugin windows are skipped
  -- so opening chat never abandons the current project.
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = augroup,
    callback = function(ev)
      if ev.buf == 0 then
        return
      end
      local ok, project = pcall(require, "mentor.project")
      if ok then
        project.focus_buffer(ev.buf)
      end
    end,
  })
end

---Configure mentor.nvim. Invalid options produce actionable errors through
---notifications and :checkhealth; the plugin then refuses to start work.
---@param opts table|nil see README configuration reference
function M.setup(opts)
  local config = require("mentor.config")
  local _, errors = config.load(opts)
  if #errors > 0 then
    for _, err in ipairs(errors) do
      vim.schedule(function()
        vim.notify(err, vim.log.levels.ERROR)
      end)
    end
    return
  end
  define_autocmds()
  -- Observer trigger autocmds are cheap and gated on per-project activation;
  -- nothing is observed until a project explicitly enables it.
  require("mentor.observer").install()
end

function M.status()
  require("mentor.ui.status").open()
end

---Close local storage and drop transient state (not a network shutdown).
function M.shutdown()
  require("mentor.ui.chat").reset()
  require("mentor.storage").close()
  require("mentor.project").reset()
end

return M
