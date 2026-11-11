-- Read-only investigation tool registry. The model (or an internal caller)
-- selects a tool name, a parameter object, and nothing else: every request
-- is validated against the tool's schema (SEC: independent of model
-- instructions), executed under the shared access policy with wall-clock and
-- output budgets, sanitized for secrets, and returned as structured data.
-- No tool writes project files or executes model-supplied commands.

local config = require("mentor.config")
local context = require("mentor.context")
local policy_mod = require("mentor.policy")
local sanitize = require("mentor.sanitize")

local files = require("mentor.tools.files")
local gitmod = require("mentor.tools.git")
local lang = require("mentor.tools.lang")

local M = {}

---@class mentor.Tool
---@field summary string
---@field params table<string, string> parameter name -> "string"|"integer"|"boolean", trailing "?" = optional
---@field handler fun(ctx: table, args: table): table

---@type table<string, mentor.Tool>
M.tools = {
  list_directory = {
    summary = "List a directory inside the authorized project scope",
    params = { path = "string?" },
    handler = files.list_directory,
  },
  read_file = {
    summary = "Read a text file; loaded buffer contents take precedence over disk",
    params = { path = "string", from_line = "integer?", to_line = "integer?" },
    handler = files.read_file,
  },
  search_files = {
    summary = "Search file paths by substring or glob",
    params = { pattern = "string", path = "string?" },
    handler = files.search_files,
  },
  search_content = {
    summary = "Search text in files and live buffers (unsaved edits included)",
    params = { query = "string", path = "string?", case_insensitive = "boolean?" },
    handler = files.search_content,
  },
  get_buffer = {
    summary = "Read a live editor buffer by number or path",
    params = { bufnr = "integer?", path = "string?", from_line = "integer?", to_line = "integer?" },
    handler = files.get_buffer,
  },
  get_diagnostics = {
    summary = "Read current editor diagnostics (freshness may be unknown)",
    params = { path = "string?" },
    handler = lang.get_diagnostics,
  },
  find_symbol = {
    summary = "Locate a definition via language tooling; explicitly unavailable without it",
    params = { path = "string", symbol = "string", line = "integer?", column = "integer?" },
    handler = lang.find_symbol,
  },
  find_references = {
    summary = "Locate symbol usages via language tooling",
    params = { path = "string", symbol = "string", line = "integer?", column = "integer?" },
    handler = lang.find_references,
  },
  get_git_status = {
    summary = "Repository state as a disk/index view (unsaved edits not included)",
    params = {},
    handler = gitmod.status,
  },
  get_git_diff = {
    summary = "Working tree or staged diff for a scoped path (disk/index view)",
    params = { path = "string?", staged = "boolean?" },
    handler = gitmod.diff,
  },
  get_git_history = {
    summary = "Recent commits (messages and changed paths, filtered by policy)",
    params = { path = "string?", limit = "integer?" },
    handler = gitmod.history,
  },
}

---Names and summaries for prompt construction (later milestones).
function M.summaries()
  local out = {}
  for name, tool in pairs(M.tools) do
    out[name] = tool.summary
  end
  return out
end

---@param opts table {project}
---@return table operation context
function M.new_operation(opts)
  local cfg = config.get()
  local policy = policy_mod.for_project(opts.project)
  return {
    project = opts.project,
    policy = policy,
    tracker = context.new_tracker(opts.project, policy),
    limits = cfg.context,
    started_at = vim.uv.now(),
    cancelled = false,
  }
end

---Validate arguments against the tool's parameter spec. Unknown parameters
---are rejected rather than ignored, so a malformed model request fails
---clearly instead of silently changing behavior.
---@param tool mentor.Tool
---@param args table
---@return string[] problems
local function validate_params(tool, args)
  local problems = {}
  if type(args) ~= "table" then
    return { "arguments must be an object" }
  end
  for key in pairs(args) do
    if tool.params[key] == nil then
      problems[#problems + 1] = "unknown parameter " .. tostring(key)
    end
  end
  for key, typ in pairs(tool.params) do
    local optional = typ:sub(-1) == "?"
    local base = optional and typ:sub(1, -2) or typ
    local value = args[key]
    if value == nil then
      if not optional then
        problems[#problems + 1] = "missing required parameter " .. key
      end
    elseif base == "string" then
      if type(value) ~= "string" or value == "" then
        problems[#problems + 1] = key .. " must be a non-empty string"
      end
    elseif base == "integer" then
      if type(value) ~= "number" or value % 1 ~= 0 then
        problems[#problems + 1] = key .. " must be an integer"
      end
    elseif base == "boolean" then
      if type(value) ~= "boolean" then
        problems[#problems + 1] = key .. " must be a boolean"
      end
    end
  end
  return problems
end

---Execute one tool call. Never throws; failures come back as structured
---results with an actionable error.
---@param ctx table operation context
---@param name string
---@param args table|nil
---@return table result {ok, ...} or {ok=false, error}
function M.run(ctx, name, args)
  if ctx.cancelled then
    return { ok = false, error = "the operation was cancelled" }
  end
  local tool = M.tools[name]
  if not tool then
    local names = {}
    for known in pairs(M.tools) do
      names[#names + 1] = known
    end
    table.sort(names)
    return {
      ok = false,
      error = "unknown tool " .. tostring(name) .. "; available: " .. table.concat(names, ", "),
    }
  end

  local problems = validate_params(tool, args or {})
  if #problems > 0 then
    return { ok = false, error = "invalid arguments: " .. table.concat(problems, "; ") }
  end
  if vim.uv.now() - ctx.started_at >= ctx.limits.max_elapsed_ms then
    return { ok = false, error = "the operation exceeded its time budget" }
  end

  local ok, result = pcall(tool.handler, ctx, args or {})
  if not ok then
    return { ok = false, error = "tool failed: " .. tostring(result) }
  end
  if type(result) ~= "table" then
    return { ok = false, error = "tool produced no structured result" }
  end

  local findings = {}
  local clean = sanitize.sanitize_tree(result, findings)
  -- ok means "the requested information is present": explicit errors and
  -- explicit unavailability both clear it; the reason fields stay intact.
  clean.ok = clean.error == nil and clean.available ~= false
  if #findings > 0 then
    clean.redacted = findings
  end
  return clean
end

return M
