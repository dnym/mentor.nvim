-- Shared path/access policy for every context source: live buffers,
-- traversal, searches, Git output, and stored context. A path is authorized
-- only through resolved-path containment — never a raw string-prefix check —
-- so symlinks cannot carry access outside an allowed root. Exclusions apply
-- on top of containment, and nested repositories stay outside the
-- parent-project policy.

local config = require("mentor.config")
local project = require("mentor.project")

local M = {}

-- Always excluded; user configuration may add patterns but cannot re-allow
-- these. The .git directory is reachable only through the constrained Git
-- adapters, never through file tools.
M.DEFAULT_EXCLUSIONS = {
  ".git",
  ".env",
  ".env.*",
  ".git-credentials",
  ".netrc",
  "*.pem",
  "*.key",
  "*.p12",
  "*.pfx",
  "id_rsa",
  "id_dsa",
  "id_ecdsa",
  "id_ed25519",
}

-- Policy generation: bumped whenever configuration is reloaded, so tracked
-- context recorded under an older policy is detected as stale.
local generation = 0

function M.bump()
  generation = generation + 1
end

function M.generation()
  return generation
end

---Compile a glob into an anchored Lua pattern. "*" stays within a segment,
---"**" crosses segments, "?" matches one non-separator character.
---@param glob string
---@return string lua pattern
local function compile(glob)
  local out = {}
  local i = 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == "*" then
      if glob:sub(i + 1, i + 1) == "*" then
        out[#out + 1] = ".*"
        i = i + 2
        if glob:sub(i, i) == "/" then
          -- "**/" also matches the empty segment ("**/x" matches "x")
          out[#out + 1] = "[^/]*"
          i = i + 1
        end
      else
        out[#out + 1] = "[^/]*"
        i = i + 1
      end
    elseif c == "?" then
      out[#out + 1] = "[^/]"
      i = i + 1
    elseif c:find("[%^%$%(%)%%%.%[%]%*%+%-%?]") then
      out[#out + 1] = "%" .. c
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return "^" .. table.concat(out) .. "$"
end

---@class mentor.PolicyAccess
---@field abspath string canonical absolute path (lexical for missing files)
---@field rel string path relative to the matched root ("" for the root)
---@field root string the authorized root that matched
---@field exists boolean whether the full path exists on disk

---@class mentor.Policy
---@field project mentor.Project
---@field roots string[] authorized roots (canonical), project root first
local Policy = {}
Policy.__index = Policy

---@param proj mentor.Project
---@return mentor.Policy
function M.for_project(proj)
  local patterns = {}
  for _, glob in ipairs(M.DEFAULT_EXCLUSIONS) do
    patterns[#patterns + 1] =
      { glob = glob, pattern = compile(glob), segment_only = not glob:find("/", 1, true) }
  end
  for _, glob in ipairs(config.get().context.exclusions) do
    patterns[#patterns + 1] =
      { glob = glob, pattern = compile(glob), segment_only = not glob:find("/", 1, true) }
  end
  local roots = { project.canonical(proj.root) }
  for _, dir in ipairs(config.get().projects.external_dirs) do
    local canonical = project.canonical(dir)
    if canonical then
      roots[#roots + 1] = canonical
    end
  end
  return setmetatable({
    project = proj,
    roots = roots,
    patterns = patterns,
    generation = generation,
  }, Policy)
end

---True when the root-relative path matches an exclusion pattern.
---@param rel string
function Policy:excluded(rel)
  if rel == "" then
    return false
  end
  for _, entry in ipairs(self.patterns) do
    if entry.segment_only then
      for segment in (rel .. "/"):gmatch("([^/]+)") do
        if segment:match(entry.pattern) then
          return true
        end
      end
    elseif rel:match(entry.pattern) then
      return true
    end
  end
  return false
end

local function reverse_join(tail)
  local forward = {}
  for i = #tail, 1, -1 do
    forward[#forward + 1] = tail[i]
  end
  return table.concat(forward, "/")
end

local function nearest_existing(dir)
  local d = dir
  local tail = {}
  while d ~= "" and d ~= "/" do
    if vim.uv.fs_stat(d) then
      return d, reverse_join(tail)
    end
    tail[#tail + 1] = vim.fn.fnamemodify(d, ":t")
    d = vim.fn.fnamemodify(d, ":h")
  end
  if vim.uv.fs_stat("/") then
    return "/", reverse_join(tail)
  end
  return nil, nil
end

---Does any directory between the root and the candidate (excluding the root
---itself) open a nested repository?
---@param root string
---@param rel string
function Policy:nested_repo(root, rel)
  if rel == "" then
    return false
  end
  local walked = root
  for segment in rel:gmatch("([^/]+)") do
    walked = walked .. "/" .. segment
    if vim.uv.fs_stat(walked .. "/.git") then
      return true
    end
  end
  return false
end

---Collapse "." and ".." segments lexically on an absolute path so traversal
---above the root is visible before any filesystem resolution.
local function normalize_lexical(path)
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == "." then
      -- skip
    elseif seg == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        parts[#parts] = nil
      else
        parts[#parts + 1] = ".."
      end
    else
      parts[#parts + 1] = seg
    end
  end
  local joined = "/" .. table.concat(parts, "/")
  if joined ~= "/" then
    joined = joined:gsub("/+$", "")
  end
  return joined
end

---Authorize a path for investigation access. The path may be absolute or
---relative to the project root, and may not exist yet (unsaved named
---buffers); resolution walks to the nearest existing ancestor so symlink
---escapes are still caught.
---@param raw string
---@return mentor.PolicyAccess|nil access, string|nil reason
function Policy:authorize(raw)
  if type(raw) ~= "string" then
    return nil, "path must be a string"
  end
  if raw == "" then
    raw = self.project.root -- empty means the project root itself
  end
  if raw:find("\0", 1, true) or raw:find("://", 1, true) then
    return nil, "not a filesystem path"
  end
  local lexical = raw:sub(1, 1) == "/" and raw or (self.project.root .. "/" .. raw)
  lexical = normalize_lexical(vim.fn.fnamemodify(lexical, ":p"))

  local anchor, tail = nearest_existing(lexical)
  if not anchor then
    return nil, "path is not reachable"
  end
  local resolved_anchor = vim.uv.fs_realpath(anchor) or anchor

  local matched ---@type string|nil
  for _, root in ipairs(self.roots) do
    if resolved_anchor == root or resolved_anchor:sub(1, #root + 1) == root .. "/" then
      matched = root
      break
    end
  end
  if not matched then
    return nil,
      "path resolves outside the authorized project root and configured external "
        .. "directories; use a path inside the project, relative to its root"
  end

  local resolved_abs = resolved_anchor
  if tail ~= "" then
    resolved_abs = resolved_anchor .. "/" .. tail
  end
  local rel = resolved_abs == matched and "" or resolved_abs:sub(#matched + 2)

  for segment in (rel .. "/"):gmatch("([^/]+)") do
    if segment == ".git" then
      return nil, "the .git directory is not available to file tools; use the Git adapters"
    end
  end
  if self:excluded(rel) then
    return nil, "path is excluded by access policy"
  end
  if matched == project.canonical(self.project.root) and self:nested_repo(matched, rel) then
    return nil, "nested repositories are separate projects and excluded from parent traversal"
  end

  return {
    abspath = resolved_abs,
    rel = rel,
    root = matched,
    exists = tail == "",
  }
end

---Expose the glob compiler for path-name searches.
M.glob_to_lua = compile

return M
