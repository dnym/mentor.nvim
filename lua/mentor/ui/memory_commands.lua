-- :MentorMemory subcommand dispatch. Thin glue: parse arguments, call the
-- memory module, report results, and regenerate any open view.

local project = require("mentor.project")
local memory = require("mentor.memory")
local view = require("mentor.ui.memory")

local M = {}

local function report(result, success_msg)
  if result.ok then
    vim.notify(success_msg, vim.log.levels.INFO)
    return true
  end
  vim.notify("mentor.nvim memory: " .. result.error, vim.log.levels.ERROR)
  return false
end

local function parse_id(value, usage)
  local id = tonumber(value or "")
  if not id or id <= 0 or id % 1 ~= 0 then
    vim.notify("mentor.nvim memory: " .. usage, vim.log.levels.ERROR)
    return nil
  end
  return math.floor(id)
end

---@param args string raw command arguments
function M.run(args)
  args = vim.trim(args or "")
  local sub = args:match("^(%S+)") or "edit"

  if sub == "edit" then
    view.open()
    return
  end

  local proj = project.ensure_current()
  if not proj then
    vim.notify("mentor.nvim: no project context", vim.log.levels.ERROR)
    return
  end

  if sub == "consolidate" then
    local _, err = require("mentor.memory.consolidate").run(proj, {
      on_note = function(text)
        vim.notify("mentor.nvim memory: " .. text, vim.log.levels.INFO)
      end,
      on_done = function(err2, info)
        view.refresh_if_open(proj)
        if err2 then
          vim.notify("mentor.nvim memory: consolidation stopped (" .. err2 .. ")", vim.log.levels.WARN)
        elseif info and info.content then
          vim.notify("mentor.nvim memory: consolidation pass finished", vim.log.levels.INFO)
        end
      end,
    })
    if err then
      vim.notify(err, vim.log.levels.WARN)
    end
    return
  end

  local rest = args:sub(#sub + 2)
  if sub == "revert" then
    local id_str, rev_str = rest:match("^(%S+)%s*(.*)$")
    local id = parse_id(id_str, "usage: :MentorMemory revert <id> [revision]")
    if not id then
      return
    end
    local entry = memory.get(id)
    if not entry then
      vim.notify("mentor.nvim memory: no entry m" .. id, vim.log.levels.ERROR)
      return
    end
    local to = parse_id(rev_str, "usage: :MentorMemory revert <id> [revision]") or (entry.revision - 1)
    if to < 1 then
      vim.notify("mentor.nvim memory: no earlier revision to revert to", vim.log.levels.ERROR)
      return
    end
    report(memory.revert(id, to, "user"), "mentor.nvim memory: m" .. id .. " reverted to revision " .. to)
  elseif sub == "delete" then
    local id = parse_id(rest, "usage: :MentorMemory delete <id>")
    if id then
      report(
        memory.delete_entry(id, "user", nil, "deleted via command"),
        "mentor.nvim memory: m" .. id .. " deleted"
      )
    end
  elseif sub == "erase" then
    local id = parse_id(rest, "usage: :MentorMemory erase <id>")
    if id then
      report(
        memory.erase(id),
        "mentor.nvim memory: m"
          .. id
          .. " and its history erased (content-free audit marker kept; chat is untouched)"
      )
    end
  elseif sub == "protect" then
    local id_str, flag = rest:match("^(%S+)%s*(%S*)$")
    local id = parse_id(id_str, "usage: :MentorMemory protect <id> on|off")
    if not id then
      return
    end
    if flag ~= "on" and flag ~= "off" then
      vim.notify("mentor.nvim memory: usage: :MentorMemory protect <id> on|off", vim.log.levels.ERROR)
      return
    end
    report(memory.set_protected(id, flag == "on"), "mentor.nvim memory: m" .. id .. " protection " .. flag)
  else
    vim.notify(
      "mentor.nvim memory: unknown subcommand '"
        .. sub
        .. "'; expected edit | revert <id> [rev] | delete <id> | erase <id> | protect <id> on|off | consolidate",
      vim.log.levels.ERROR
    )
  end

  view.refresh_if_open(proj)
end

return M
