-- Persist the paths contributing to an investigation result in the existing
-- source column, so replay can apply the current policy to every source.
local M = {}
local prefix = "mentor-paths:"
local withheld = "[result withheld: its source is excluded by the current access policy]"

function M.capture(ctx, args, result)
  local paths, seen = {}, {}
  local function add(path)
    if type(path) == "string" and path ~= "" and not seen[path] then
      seen[path] = true
      paths[#paths + 1] = path
    end
  end
  add(args.path)
  for _, path in ipairs(ctx.provenance or {}) do
    add(path)
  end
  for _, src in pairs(ctx.tracker.sources) do
    if src.kind == "disk" then
      add(src.path)
    elseif vim.api.nvim_buf_is_valid(src.bufnr) then
      add(vim.api.nvim_buf_get_name(src.bufnr))
    end
  end
  local function visit(value)
    if type(value) ~= "table" then
      return
    end
    add(value.path)
    add(value.rel)
    if type(value.files) == "table" then
      for _, path in ipairs(value.files) do
        add(path)
      end
    end
    for _, child in pairs(value) do
      if type(child) == "table" then
        visit(child)
      end
    end
  end
  visit(result)
  return prefix .. vim.json.encode(paths)
end

function M.authorized(source, tool, policy)
  if source and source:sub(1, #prefix) == prefix then
    local ok, paths = pcall(vim.json.decode, source:sub(#prefix + 1))
    if not ok or type(paths) ~= "table" then
      return false
    end
    for _, path in ipairs(paths) do
      if not policy:authorize(path) then
        return false
      end
    end
    return true
  end
  -- Older multi-source results did not record their contributing paths.
  local single = tool == nil or tool == "read_file" or tool == "get_buffer"
  if not single then
    return false
  end
  return source ~= nil and policy:authorize(source) ~= nil
end

M.withheld = withheld
return M
