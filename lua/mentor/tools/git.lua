-- Constrained Git adapters: fixed argument construction only (the model can
-- select a validated path, a staged flag, and a bounded commit count; it
-- never controls commands, flags, or shell arguments). External diff/text
-- conversion and pagers are disabled, excluded paths are filtered out, and
-- output is sanitized and size-bounded. Git results are labeled as
-- disk/index views: they do not include unsaved buffer edits.

local M = {}

local GIT_FLAGS = { "-c", "core.quotepath=false", "-c", "color.ui=false" }

---@param ctx table operation context
---@param subcmd string[] fixed git subcommand and flags
---@return table|nil result {stdout} or {error} or {available=false}
local function git_run(ctx, subcmd)
  if not ctx.project.is_git then
    return { available = false, reason = "the project is not a Git repository" }
  end
  ctx.tracker:record_checkout()
  local argv = { "git", "--no-pager", "--literal-pathspecs", "-C", ctx.project.root, "--no-optional-locks" }
  vim.list_extend(argv, GIT_FLAGS)
  vim.list_extend(argv, subcmd)
  local budget = math.min(ctx.limits.max_elapsed_ms + 3000, 15000)
  local ok, res = pcall(vim.system, argv, { text = true, timeout = budget })
  if not ok then
    return { error = "could not start git" }
  end
  local out = res:wait()
  if out.code ~= 0 then
    local detail = vim.trim(out.stderr or ""):sub(1, 400)
    return { error = "git " .. subcmd[1] .. " failed", detail = detail }
  end
  return { stdout = out.stdout or "" }
end

local function cap(text, max)
  if #text <= max then
    return text, false
  end
  return text:sub(1, max) .. "\n[truncated]", true
end

---@param ctx table
function M.status(ctx, _args)
  local run = git_run(ctx, { "status", "--porcelain=v1", "--untracked-files=all" })
  if not run.stdout then
    return run
  end
  local entries, filtered, truncated = {}, 0, false
  for line in run.stdout:gmatch("[^\n]+") do
    if #entries >= ctx.limits.max_list_entries then
      truncated = true
      break
    end
    -- porcelain v1: two status columns, a space, then the path
    -- (renames are "old -> new"; report the new path)
    local xy = line:sub(1, 2)
    local path = line:sub(4)
    -- rename "old -> new": keep the new path; expand "{old => new}" segments
    path = path:match(".*%->%s+(.*)$") or path
    path = path:gsub("{(.-)%s*=>%s*(.-)}", "%2"):gsub("//", "/")
    path = path:gsub('^"', ""):gsub('"$', "")
    if ctx.policy:excluded(path) then
      filtered = filtered + 1
    else
      entries[#entries + 1] = { status = xy, path = path }
    end
  end
  return {
    view = "disk/index (unsaved buffer edits are not included)",
    entries = entries,
    filtered_excluded = filtered,
    truncated = truncated,
  }
end

---@param ctx table
---@param args table {path?, staged?}
function M.diff(ctx, args)
  local subcmd = { "diff", "--no-ext-diff", "--no-textconv", "--no-renames" }
  if args.staged then
    subcmd[#subcmd + 1] = "--cached"
  end
  local pathspec
  if args.path then
    local access, why = ctx.policy:authorize(args.path)
    if not access then
      return { error = why }
    end
    pathspec = access.rel ~= "" and access.rel or nil
  end
  local names_cmd = vim.list_extend(vim.deepcopy(subcmd), { "--name-only", "-z" })
  if pathspec then
    vim.list_extend(names_cmd, { "--", pathspec })
  end
  local run = git_run(ctx, names_cmd)
  if not run.stdout then
    return run
  end
  local parts, bytes, truncated = {}, 0, false
  for _, path in ipairs(vim.split(run.stdout, "\0", { plain = true, trimempty = true })) do
    local access = ctx.policy:authorize(path)
    if access then
      local file_cmd = { "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=3" }
      if args.staged then
        file_cmd[#file_cmd + 1] = "--cached"
      end
      vim.list_extend(file_cmd, { "--", path })
      local file = git_run(ctx, file_cmd)
      if not file.stdout then
        return file
      end
      ctx.provenance = ctx.provenance or {}
      ctx.provenance[#ctx.provenance + 1] = access.abspath
      parts[#parts + 1] = file.stdout
      bytes = bytes + #file.stdout
      if bytes > ctx.limits.max_output_bytes then
        truncated = true
        break
      end
    end
  end
  local out, capped = cap(table.concat(parts), ctx.limits.max_output_bytes)
  return {
    view = "disk/index (unsaved buffer edits are not included)",
    diff = out,
    truncated = truncated or capped,
  }
end

---@param ctx table
---@param args table {path?, limit?}
function M.history(ctx, args)
  local limit = math.max(1, math.min(args.limit or ctx.limits.git_history_limit, 100))
  local subcmd = {
    "log",
    "--date=short",
    "--max-count=" .. limit,
    "--format=%H%x09%ad%x09%an%x09%s",
    "--name-only",
  }
  if args.path then
    local access, why = ctx.policy:authorize(args.path)
    if not access then
      return { error = why }
    end
    subcmd[#subcmd + 1] = "--"
    subcmd[#subcmd + 1] = access.rel
  end
  local run = git_run(ctx, subcmd)
  if not run.stdout then
    return run
  end

  local commits, current, filtered = {}, nil, 0
  for line in run.stdout:gmatch("[^\r\n]+") do
    local sha, date, author, subject = line:match("^([0-9a-f]+)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if sha then
      current = { sha = sha, date = date, author = author, subject = subject, files = {} }
      commits[#commits + 1] = current
    elseif current then
      if ctx.policy:excluded(line) then
        filtered = filtered + 1
      else
        current.files[#current.files + 1] = line
      end
    end
  end
  local truncated = #commits >= limit
  return {
    view = "history (commit contents are not included; unsaved edits are never present)",
    commits = commits,
    filtered_excluded = filtered,
    possibly_more = truncated,
  }
end

return M
