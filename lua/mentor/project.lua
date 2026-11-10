-- Project identity: canonical absolute working-tree root.
-- Resolution prefers the nearest containing Git root; non-Git projects use an
-- explicitly configured root or the working directory captured at activation.
-- Each Git worktree is a separate project; nested repositories resolve to
-- their own innermost root and are excluded from parent traversal (M2 tools).

local M = {}

---@class mentor.Project
---@field identity string canonical root path, unique per worktree
---@field root string
---@field is_git boolean
---@field git_common_dir string|nil
---@field id integer|nil storage row id, assigned on activation

-- Fixed, application-built argument lists only; the model never controls
-- commands. --no-optional-locks avoids writing to the repository
-- for read-only queries.
---@param cwd string
---@param args string[] fixed arguments appended after "git -C <cwd>"
local function git(cwd, args)
  local argv = { "git", "-C", cwd, "--no-optional-locks" }
  vim.list_extend(argv, args)
  local ok, res = pcall(vim.system, argv, { text = true, timeout = 2000 })
  if not ok then
    return nil
  end
  local out = res:wait()
  if out.code ~= 0 then
    return nil
  end
  return vim.trim(out.stdout or "")
end

---Canonical absolute path: symlinks resolved, trailing slashes removed.
---@param path string|nil
---@return string|nil
function M.canonical(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local resolved = vim.uv.fs_realpath(path)
  if not resolved then
    resolved = vim.fn.fnamemodify(path, ":p")
  end
  resolved = vim.fn.fnamemodify(resolved, ":p"):gsub("/+$", "")
  if resolved == "" then
    return "/"
  end
  return resolved
end

---Directory that anchors project resolution for a buffer. Buffers without a
---file (scratch, terminal) fall back to the instance working directory.
local function buffer_dir(bufnr)
  local name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  if name == "" or name:find("://", 1, true) then
    return vim.uv.cwd()
  end
  if
    vim.fn.bufloaded(bufnr) == 1
    and vim.fn.getbufvar(bufnr, "&modified") == 1
    and vim.fn.filereadable(name) == 0
  then
    -- Unsaved new buffer: its name may already be a path under a directory.
    local parent = vim.fn.fnamemodify(name, ":h")
    return vim.fn.isdirectory(parent) == 1 and parent or vim.uv.cwd()
  end
  local full = vim.fn.fnamemodify(name, ":p")
  local parent = vim.fn.isdirectory(full) == 1 and full or vim.fn.fnamemodify(full, ":h")
  return parent
end

local cache = {} -- canonical dir -> Git-backed project record

---Nearest existing ancestor, so unsaved buffers under paths that do not
---exist on disk yet still resolve through their containing project.
local function existing_ancestor(dir)
  local d = dir
  while d ~= "" and d ~= "/" do
    if vim.uv.fs_stat(d) then
      return d
    end
    d = vim.fn.fnamemodify(d, ":h")
  end
  return "/"
end

---Builds the project record for a directory, preferring the nearest Git root.
---@param dir string
---@return mentor.Project|nil
local function resolve_dir(dir)
  local anchor = M.canonical(dir)
  if not anchor then
    return nil
  end
  local cached = cache[anchor]
  if cached then
    return cached
  end

  local toplevel = git(existing_ancestor(anchor), { "rev-parse", "--show-toplevel" })
  if toplevel then
    local root = M.canonical(toplevel)
    local common = git(anchor, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
    local rec = {
      identity = root,
      root = root,
      is_git = true,
      git_common_dir = common and M.canonical(common) or nil,
    }
    cache[anchor] = rec
    return rec
  end

  -- Non-Git: explicit root wins; otherwise the directory captured here
  -- (activation directory / instance working directory).
  local configured = require("mentor.config").get().projects.fallback_root
  local root = M.canonical(configured) or anchor
  return { identity = root, root = root, is_git = false, git_common_dir = nil }
end

---Project for an explicit directory (no activation side effects).
---@param dir string
---@return mentor.Project|nil
function M.for_dir(dir)
  return resolve_dir(dir)
end

---Project for a source buffer. Plugin-owned buffers carry their originating
---project binding so opening a plugin window cannot retarget context.
---@param bufnr integer
---@return mentor.Project|nil
function M.for_buf(bufnr)
  local bound = vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].mentor_project or nil
  if bound then
    return resolve_dir(bound)
  end
  return resolve_dir(buffer_dir(bufnr))
end

---@param bufnr integer
---@return mentor.Project|nil
function M.for_window(winid)
  return M.for_buf(vim.api.nvim_win_get_buf(winid))
end

---@type mentor.Project|nil
local current

---Registers the project in storage and makes it the focused project.
---@param rec mentor.Project|nil
local function activate(rec)
  if not rec then
    return nil
  end
  if not rec.id then
    rec.id = require("mentor.storage.records").projects.touch(rec)
  end
  current = rec
  return rec
end

---Ensures a focused project exists, activating from the current buffer.
function M.ensure_current()
  if current then
    return current
  end
  return activate(M.for_buf(0))
end

---Updates the focused project when a normal editor buffer is entered.
---Called from the setup autocmds; plugin windows are skipped so entering
---chat does not abandon the current project.
function M.focus_buffer(bufnr)
  if vim.b[bufnr] and vim.b[bufnr].mentor_project then
    return current
  end
  if vim.bo[bufnr].buftype ~= "" then
    return current
  end
  return activate(M.for_buf(bufnr))
end

---@return mentor.Project|nil
function M.current()
  return current
end

---True for directories inside a Git repository other than the given root,
---used by traversal (M2) to exclude nested repositories by default.
---@param dir string
---@param root string
function M.is_nested_repo(dir, root)
  local canonical_dir, canonical_root = M.canonical(dir), M.canonical(root)
  if not canonical_dir or canonical_dir == canonical_root then
    return false
  end
  local st = vim.uv.fs_stat((canonical_dir .. "/.git"))
  return st ~= nil
end

---Drops resolution caches (tests and configuration changes).
function M.reset()
  cache = {}
  current = nil
end

return M
