-- Context source tracking. Every investigation records the sources it used
-- (buffer versions, disk fingerprints, policy generation, checkout), and the
-- tracker rechecks them before results are published. Any change invalidates
-- pending results: buffer edits, external file changes, policy changes, and
-- detected checkouts.

local project = require("mentor.project")

local M = {}

---@class mentor.Tracker
---@field sources table<string, table> key -> source record
---@field policy_generation integer
---@field checkout string|nil recorded Git HEAD (nil = not recorded)
---@field project mentor.Project
local Tracker = {}
Tracker.__index = Tracker

---@param proj mentor.Project
---@param policy mentor.Policy
---@return mentor.Tracker
function M.new_tracker(proj, policy)
  return setmetatable({
    sources = {},
    policy_generation = policy.generation,
    checkout = nil,
    project = proj,
  }, Tracker)
end

---Record a disk file source (fingerprinted by mtime+size).
---@param abspath string
---@param stat table from vim.uv.fs_stat
function Tracker:disk(abspath, stat)
  if type(stat) ~= "table" or stat.mtime == nil then
    return
  end
  self.sources["disk:" .. abspath] = {
    kind = "disk",
    path = abspath,
    mtime_sec = stat.mtime.sec,
    mtime_nsec = stat.mtime.nsec,
    size = stat.size,
  }
end

---Record a live buffer source (versioned by changedtick).
---@param bufnr integer
function Tracker:buffer(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    self.sources["buf:" .. bufnr] = {
      kind = "buffer",
      bufnr = bufnr,
      version = vim.api.nvim_buf_get_changedtick(bufnr),
    }
  end
end

---Record the current checkout so a later checkout change invalidates work.
function Tracker:record_checkout()
  if not self.project.is_git then
    return
  end
  local ok, res = pcall(vim.system, {
    "git",
    "-C",
    self.project.root,
    "--no-optional-locks",
    "rev-parse",
    "HEAD",
  }, { text = true, timeout = 2000 })
  if ok then
    local out = res:wait()
    if out.code == 0 then
      self.checkout = vim.trim(out.stdout or "")
    end
  end
end

---Recheck every recorded dependency.
---@return boolean up_to_date, table[] invalidated
function Tracker:verify()
  local invalidated = {}
  if self.policy_generation ~= require("mentor.policy").generation() then
    invalidated[#invalidated + 1] = { kind = "policy", reason = "access policy changed" }
  end

  for key, src in pairs(self.sources) do
    if src.kind == "buffer" then
      if
        not vim.api.nvim_buf_is_valid(src.bufnr)
        or vim.api.nvim_buf_get_changedtick(src.bufnr) ~= src.version
      then
        invalidated[#invalidated + 1] = {
          kind = "buffer",
          ref = key,
          reason = "buffer changed or was closed",
        }
      end
    elseif src.kind == "disk" then
      local stat = vim.uv.fs_stat(src.path)
      if not stat then
        invalidated[#invalidated + 1] = { kind = "disk", ref = key, reason = "file disappeared" }
      elseif
        stat.size ~= src.size
        or stat.mtime.sec ~= src.mtime_sec
        or stat.mtime.nsec ~= src.mtime_nsec
      then
        invalidated[#invalidated + 1] = { kind = "disk", ref = key, reason = "file changed on disk" }
      end
    end
  end

  if self.checkout then
    local ok, res = pcall(vim.system, {
      "git",
      "-C",
      self.project.root,
      "--no-optional-locks",
      "rev-parse",
      "HEAD",
    }, { text = true, timeout = 2000 })
    local current = nil
    if ok then
      local out = res:wait()
      if out.code == 0 then
        current = vim.trim(out.stdout or "")
      end
    end
    if current ~= self.checkout then
      invalidated[#invalidated + 1] = { kind = "checkout", reason = "the checkout changed" }
    end
  end

  return #invalidated == 0, invalidated
end

---A human-readable source list for provenance display (status buffers,
---later UIs). Absolute paths stay local; this never leaves the machine.
---@return table[]
function Tracker:sources_list()
  local out = {}
  for _, src in pairs(self.sources) do
    if src.kind == "disk" then
      out[#out + 1] = { kind = "disk", path = src.path, size = src.size }
    else
      out[#out + 1] = {
        kind = "buffer",
        bufnr = src.bufnr,
        name = vim.api.nvim_buf_is_valid(src.bufnr) and vim.api.nvim_buf_get_name(src.bufnr) or "(closed)",
      }
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.path or a.name) < tostring(b.path or b.name)
  end)
  return out
end

---True when the buffer belongs to the tracker's project (same canonical
---identity), used to stop tools from pulling in sibling-project buffers.
---@param bufnr integer
function Tracker:same_project(bufnr)
  local rec = project.for_buf(bufnr)
  return rec ~= nil and rec.identity == self.project.identity
end

return M
