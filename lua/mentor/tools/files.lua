-- File/buffer investigation tools. Every access goes through the shared
-- access policy; loaded buffer contents take precedence over disk contents,
-- including unsaved named buffers that do not yet exist on disk. Traversal,
-- input size, file size, output, and elapsed work are all bounded, and
-- binary files are skipped with an explicit result. Sources are recorded on
-- the operation tracker so later changes invalidate the investigation.

local project = require("mentor.project")
local policy_glob = require("mentor.policy").glob_to_lua

local M = {}

local function cap_text(s, max)
  if type(s) ~= "string" then
    return s, false
  end
  if #s <= max then
    return s, false
  end
  return s:sub(1, max) .. "\n[truncated]", true
end

local function time_up(ctx)
  return vim.uv.now() - ctx.started_at >= ctx.limits.max_elapsed_ms
end

---Read lines [from, to] (1-based, inclusive) without loading the file whole:
---streams fixed-size chunks, collects at most (to - from + 1) lines, and
---stops early at max_bytes or the elapsed budget. Returns the joined text
---and whether collection stopped early (byte or time stop).
---@param path string
---@param from integer
---@param to integer
---@param max_bytes integer
---@param ctx table operation context
---@return string|nil text, boolean stopped_early
local function read_line_slice(path, from, to, max_bytes, ctx)
  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then
    return nil, false
  end
  local wanted = to >= from and (to - from + 1) or 0
  local lines, pending, lineno, bytes = {}, "", 1, 0
  local stopped_early = false
  local function push(text)
    if lineno >= from and #lines < wanted then
      lines[#lines + 1] = text
      bytes = bytes + #text + 1
    end
    lineno = lineno + 1
  end
  while #lines < wanted and bytes < max_bytes do
    local data = vim.uv.fs_read(fd, 65536, 0)
    if not data or data == "" then
      break
    end
    local buf = pending .. data
    local pos = 1
    while true do
      local nl = buf:find("\n", pos, true)
      if not nl then
        pending = buf:sub(pos)
        break
      end
      push(buf:sub(pos, nl - 1))
      pos = nl + 1
      if bytes >= max_bytes or #lines >= wanted then
        pending = ""
        break
      end
    end
    if bytes >= max_bytes or #lines >= wanted then
      break
    end
    if time_up(ctx) then
      stopped_early = true
      break
    end
  end
  if not stopped_early and #lines < wanted and bytes < max_bytes and pending ~= "" then
    push(pending) -- final line without a trailing newline
  end
  vim.uv.fs_close(fd)
  return table.concat(lines, "\n"), stopped_early
end

---Find a loaded buffer whose canonical path matches an authorized access.
---@param abspath string
---@return integer|nil
function M.buffer_for_path(abspath)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.bufloaded(buf) == 1 then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and not name:find("://", 1, true) then
        if project.canonical(name) == abspath then
          return buf
        end
      end
    end
  end
  return nil
end

---True when the file's first bytes contain NUL (binary).
local function looks_binary(path)
  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then
    return false
  end
  local data = vim.uv.fs_read(fd, 512, 0)
  vim.uv.fs_close(fd)
  return data ~= nil and data:find("\0", 1, true) ~= nil
end

---Uniform directory iterator across libuv builds (closure or handle form).
local function scan_dir_entries(path)
  local it = vim.uv.fs_scandir(path)
  if it == nil then
    return function()
      return nil
    end
  end
  if type(it) == "function" then
    return it
  end
  return function()
    return vim.uv.fs_scandir_next(it)
  end
end

---@param ctx table operation context
---@param args table {path}
function M.list_directory(ctx, args)
  local rel = args.path or ""
  local access, why = ctx.policy:authorize(rel)
  if not access then
    return { error = why }
  end
  local stat = vim.uv.fs_stat(access.abspath)
  if not access.exists or not stat then
    return { error = "directory does not exist; check the path with search_files or list the parent" }
  end
  if stat.type ~= "directory" then
    return { error = "path is not a directory; use read_file" }
  end

  local entries, skipped = {}, { excluded = 0, nested_repos = 0, symlinks = 0 }
  local truncated = false
  local dir_iter = scan_dir_entries(access.abspath)
  ctx.tracker:disk(access.abspath, stat)
  while true do
    local name, typ = dir_iter()
    if not name then
      break
    end
    if time_up(ctx) then
      truncated = true
      break
    end
    local child_rel = access.rel == "" and name or (access.rel .. "/" .. name)
    if typ == "link" then
      skipped.symlinks = skipped.symlinks + 1
    elseif ctx.policy:excluded(child_rel) then
      skipped.excluded = skipped.excluded + 1
    elseif
      typ == "directory"
      and access.root == project.canonical(ctx.project.root)
      and vim.uv.fs_stat(access.abspath .. "/" .. name .. "/.git")
    then
      skipped.nested_repos = skipped.nested_repos + 1
    else
      if #entries >= ctx.limits.max_list_entries then
        truncated = true
        break
      end
      entries[#entries + 1] = { name = name, rel = child_rel, type = typ }
    end
  end
  table.sort(entries, function(a, b)
    return a.rel < b.rel
  end)
  return { path = access.rel, entries = entries, skipped = skipped, truncated = truncated }
end

---@param ctx table
---@param args table {path, from_line?, to_line?}
function M.read_file(ctx, args)
  local access, why = ctx.policy:authorize(args.path)
  if not access then
    return { error = why }
  end
  local buf = M.buffer_for_path(access.abspath)
  local stat = vim.uv.fs_stat(access.abspath)

  if not buf and not stat then
    return {
      error = "file does not exist on disk and is not loaded in a buffer; "
        .. "check the path with list_directory or search_files",
    }
  end
  if not buf and stat.type ~= "file" then
    return { error = "path is not a regular file; if it is a directory use list_directory" }
  end
  if not buf and stat.size > ctx.limits.max_file_bytes then
    -- Above the whole-file cap an explicit, bounded range is honored: the
    -- remedy named in an error message must be executable. The slice is
    -- read server-side (line range), never the whole file.
    if args.from_line ~= nil and args.to_line ~= nil then
      if looks_binary(access.abspath) then
        ctx.tracker:disk(access.abspath, stat)
        return { path = access.rel, binary = true, skipped = true, size = stat.size }
      end
      local from = math.max(1, args.from_line)
      local to = math.max(0, args.to_line)
      local slice, stopped_early = read_line_slice(access.abspath, from, to, ctx.limits.max_output_bytes, ctx)
      if slice == nil then
        return { error = "file became unreadable" }
      end
      local truncated
      slice, truncated = cap_text(slice, ctx.limits.max_output_bytes)
      truncated = truncated or stopped_early
      ctx.tracker:disk(access.abspath, stat)
      return {
        path = access.rel,
        source = "disk",
        unsaved = false,
        from_line = from,
        to_line = to,
        content = slice,
        truncated = truncated,
        partial = true,
        size = stat.size,
      }
    end
    return {
      error = string.format(
        "file is %d bytes, above context.max_file_bytes (%d); to read a bounded slice supply "
          .. "both from_line and to_line, or inspect with search_content",
        stat.size,
        ctx.limits.max_file_bytes
      ),
    }
  end
  if not buf and looks_binary(access.abspath) then
    ctx.tracker:disk(access.abspath, stat)
    return { path = access.rel, binary = true, skipped = true, size = stat.size }
  end

  local from = math.max(1, args.from_line or 1)
  local to = args.to_line and math.max(0, args.to_line) or nil
  local content, source, unsaved

  if buf then
    local lines = vim.api.nvim_buf_get_lines(buf, from - 1, to or -1, false)
    content = table.concat(lines, "\n")
    source = "buffer"
    unsaved = vim.api.nvim_get_option_value("modified", { buf = buf })
    ctx.tracker:buffer(buf)
    if stat then
      ctx.tracker:disk(access.abspath, stat)
    end
  else
    local lines = vim.fn.readfile(access.abspath)
    if to then
      local slice = {}
      for i = from, math.min(to, #lines) do
        slice[#slice + 1] = lines[i]
      end
      lines = slice
    elseif from > 1 then
      local slice = {}
      for i = from, #lines do
        slice[#slice + 1] = lines[i]
      end
      lines = slice
    end
    content = table.concat(lines, "\n")
    source = "disk"
    unsaved = false
    ctx.tracker:disk(access.abspath, stat)
  end

  local truncated
  content, truncated = cap_text(content, ctx.limits.max_output_bytes)
  return {
    path = access.rel,
    source = source,
    unsaved = unsaved,
    from_line = from,
    to_line = to,
    content = content,
    truncated = truncated,
  }
end

---@param ctx table
---@param args table {pattern} substring, or glob when it contains * ? or **
function M.search_files(ctx, args)
  if type(args.pattern) ~= "string" or args.pattern == "" then
    return { error = "pattern must be a non-empty string" }
  end
  local access, why = ctx.policy:authorize(args.path or "")
  if not access then
    return { error = why }
  end
  local is_glob = args.pattern:find("[*?]", 1, true) ~= nil
  local glob_pattern = is_glob and policy_glob(args.pattern) or nil
  local matches, visited, truncated = {}, 0, false
  local stack = { access.rel }
  while #stack > 0 do
    local dir_rel = table.remove(stack)
    local dir_access = ctx.policy:authorize(dir_rel)
    if dir_access then
      ctx.tracker:disk(dir_access.abspath, vim.uv.fs_stat(dir_access.abspath) or {})
      local dir_iter = scan_dir_entries(dir_access.abspath)
      while true do
        local name, typ = dir_iter()
        if not name then
          break
        end
        visited = visited + 1
        if visited > ctx.limits.max_search_files or time_up(ctx) then
          truncated = true
          break
        end
        local child_rel = dir_access.rel == "" and name or (dir_access.rel .. "/" .. name)
        if typ == "link" then
          -- links are not followed during traversal; their targets require
          -- explicit authorization
        elseif not ctx.policy:excluded(child_rel) then
          local hit = false
          if glob_pattern then
            hit = child_rel:match(glob_pattern) ~= nil or name:match(glob_pattern) ~= nil
          else
            hit = child_rel:find(args.pattern, 1, true) ~= nil
          end
          if hit and #matches < ctx.limits.max_list_entries then
            matches[#matches + 1] = { rel = child_rel, type = typ }
          end
          if typ == "directory" then
            stack[#stack + 1] = child_rel
          end
        end
      end
    end
    if truncated then
      break
    end
  end
  return { matches = matches, files_visited = visited, truncated = truncated }
end

---@param ctx table
---@param args table {query, path?, case_insensitive?}
function M.search_content(ctx, args)
  if type(args.query) ~= "string" or args.query == "" then
    return { error = "query must be a non-empty string" }
  end
  local access, why = ctx.policy:authorize(args.path or "")
  if not access then
    return { error = why }
  end
  local ci = args.case_insensitive ~= false
  local needle = ci and args.query:lower() or args.query

  local matches, skipped = {}, { binary = 0, excluded = 0, too_large = 0, unreadable = 0 }
  local files_searched, bytes_scanned, truncated, truncated_reason = 0, 0, false, nil
  local searched_paths = {}

  local function add_hit(entry)
    entry.text = (entry.text or ""):sub(1, 200)
    matches[#matches + 1] = entry
  end

  local function scan_text(source_label, lines, extra)
    for idx, line in ipairs(lines) do
      local hay = ci and line:lower() or line
      if hay:find(needle, 1, true) then
        local entry = { line = idx, text = line }
        for k, v in pairs(source_label) do
          entry[k] = v
        end
        if extra then
          for k, v in pairs(extra) do
            entry[k] = v
          end
        end
        add_hit(entry)
        if #matches >= ctx.limits.max_matches then
          return true
        end
      end
    end
    return false
  end

  -- Loaded project buffers first: unsaved edits must be visible.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.bufloaded(buf) == 1 and vim.api.nvim_buf_get_name(buf) ~= "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if not name:find("://", 1, true) and ctx.tracker:same_project(buf) then
        local canon = project.canonical(name)
        local in_scope = canon ~= nil
          and (canon == access.abspath or canon:sub(1, #access.abspath + 1) == access.abspath .. "/")
        local acc = in_scope and ctx.policy:authorize(canon)
        if acc then
          searched_paths[canon] = true
          ctx.tracker:buffer(buf)
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          bytes_scanned = bytes_scanned
            + (function()
              local total = 0
              for _, l in ipairs(lines) do
                total = total + #l + 1
              end
              return total
            end)()
          local full = scan_text(
            { path = acc.rel, unsaved = vim.api.nvim_get_option_value("modified", { buf = buf }) },
            lines
          )
          files_searched = files_searched + 1
          if full or #matches >= ctx.limits.max_matches then
            truncated, truncated_reason = true, "max_matches"
          end
        end
      end
    end
  end

  -- Then disk traversal under the authorized root.
  if not truncated then
    local stack = { access.rel }
    local stop = false
    local function stop_here(reason)
      truncated, truncated_reason, stop = true, reason, true
    end
    local function scan_dir(dir_rel)
      local dir_access = ctx.policy:authorize(dir_rel)
      if not dir_access then
        return
      end
      local dir_stat = vim.uv.fs_stat(dir_access.abspath)
      if dir_stat then
        ctx.tracker:disk(dir_access.abspath, dir_stat)
      end
      local dir_iter = scan_dir_entries(dir_access.abspath)
      while true do
        local name, typ = dir_iter()
        if not name or stop then
          return
        end
        local child_rel = dir_access.rel == "" and name or (dir_access.rel .. "/" .. name)
        if typ == "link" then
          -- not followed; see list_directory
        elseif ctx.policy:excluded(child_rel) then
          skipped.excluded = skipped.excluded + 1
        elseif
          typ == "directory"
          and dir_access.root == project.canonical(ctx.project.root)
          and vim.uv.fs_stat(dir_access.abspath .. "/" .. name .. "/.git")
        then
          skipped.excluded = skipped.excluded + 1
        elseif typ == "directory" then
          stack[#stack + 1] = child_rel
        elseif typ == "file" then
          if files_searched >= ctx.limits.max_search_files then
            return stop_here("max_search_files")
          end
          if time_up(ctx) then
            return stop_here("elapsed")
          end
          local file_access = ctx.policy:authorize(child_rel)
          if file_access and not searched_paths[file_access.abspath] then
            local stat = vim.uv.fs_stat(file_access.abspath)
            if stat then
              if stat.size > ctx.limits.max_file_bytes then
                skipped.too_large = skipped.too_large + 1
              elseif looks_binary(file_access.abspath) then
                skipped.binary = skipped.binary + 1
              else
                local lines = vim.fn.readfile(file_access.abspath)
                if lines == nil then
                  skipped.unreadable = skipped.unreadable + 1
                else
                  searched_paths[file_access.abspath] = true
                  files_searched = files_searched + 1
                  bytes_scanned = bytes_scanned + stat.size
                  ctx.tracker:disk(file_access.abspath, stat)
                  if scan_text({ path = child_rel, unsaved = false }, lines) then
                    return stop_here("max_matches")
                  end
                end
              end
            end
          end
        end
      end
    end
    while #stack > 0 and not stop do
      scan_dir(table.remove(stack))
    end
  end

  return {
    matches = matches,
    files_searched = files_searched,
    bytes_scanned = bytes_scanned,
    skipped = skipped,
    truncated = truncated,
    truncated_reason = truncated_reason,
  }
end

---@param ctx table
---@param args table {bufnr?, path?, from_line?, to_line?}
function M.get_buffer(ctx, args)
  local buf ---@type integer|nil
  if args.bufnr ~= nil then
    buf = args.bufnr
  elseif args.path then
    local access, why = ctx.policy:authorize(args.path)
    if not access then
      return { error = why }
    end
    buf = M.buffer_for_path(access.abspath)
    if not buf then
      -- Errors come back to the model verbatim, so state the fix: read_file
      -- already serves disk files (with loaded buffers taking precedence).
      if vim.uv.fs_stat(access.abspath) then
        return { error = "no loaded buffer for that path; use read_file to read this file" }
      end
      return {
        error = "no loaded buffer for that path and no such file on disk; "
          .. "check the path with list_directory or search_files, or use read_file for a real path",
      }
    end
  else
    return { error = "provide bufnr or path; to read a file from disk use read_file" }
  end
  if not vim.api.nvim_buf_is_valid(buf) or vim.fn.bufloaded(buf) ~= 1 then
    return {
      error = "buffer is not valid or not loaded (it may have been closed); "
        .. "use read_file with the path instead",
    }
  end
  if not ctx.tracker:same_project(buf) then
    return { error = "the buffer belongs to a different project" }
  end
  ctx.tracker:buffer(buf)

  local name = vim.api.nvim_buf_get_name(buf)
  local rel = name
  if name ~= "" then
    local canon = project.canonical(name)
    if canon and canon:sub(1, #ctx.project.root + 1) == ctx.project.root .. "/" then
      rel = canon:sub(#ctx.project.root + 2)
    end
  end
  local from = math.max(1, args.from_line or 1)
  local to = args.to_line or -1
  local lines = vim.api.nvim_buf_get_lines(buf, from - 1, to, false)
  local content = table.concat(lines, "\n")
  local truncated
  content, truncated = cap_text(content, ctx.limits.max_output_bytes)
  return {
    bufnr = buf,
    name = rel,
    modified = vim.api.nvim_get_option_value("modified", { buf = buf }),
    changedtick = vim.api.nvim_buf_get_changedtick(buf),
    line_count = vim.api.nvim_buf_line_count(buf),
    from_line = from,
    content = content,
    truncated = truncated,
  }
end

return M
