-- Scoped repositories over the storage adapter. Callers never build
-- arbitrary queries against persisted entities; they go through these
-- parameterized methods that require an explicit scope.

local storage = require("mentor.storage")

local M = {}
local projects = {}
M.projects = projects

---@class mentor.ProjectRecord
---@field identity string canonical absolute working-tree root
---@field root string
---@field is_git boolean
---@field git_common_dir string|nil

---Returns the stored row id for a project, creating it on first use.
---@param rec mentor.ProjectRecord
---@return integer id
function projects.touch(rec)
  local row = storage.query("SELECT id FROM project WHERE identity = ?;", { rec.identity })[1]
  if row then
    return row.id
  end
  local _, id = storage.execute(
    "INSERT INTO project (identity, root, is_git, git_common_dir, created_at) VALUES (?, ?, ?, ?, ?);",
    { rec.identity, rec.root, rec.is_git, rec.git_common_dir, math.floor(vim.uv.now()) }
  )
  return id
end

---@param identity string
---@return table|nil row
function projects.get(identity)
  return storage.query("SELECT * FROM project WHERE identity = ?;", { identity })[1]
end

---@return integer
function projects.count()
  return storage.scalar("SELECT COUNT(*) FROM project;") or 0
end

return M
