-- Model-facing memory operations. These are the assistant's only write path,
-- and it is strictly confined to designated memory storage: handlers go
-- through the memory module (never raw queries), can never touch the
-- filesystem, and inherit the shared schema validation, sanitization, and
-- output caps of the tool registry. Deletion and update require the revision
-- the model was shown, so stale concurrent writes fail clearly.

local memory = require("mentor.memory")

local M = {}

local LIST_LIMIT = 30

---@param entry mentor.MemoryEntry
---@param include_content boolean
local function describe(entry, include_content)
  local out = {
    id = entry.id,
    revision = entry.revision,
    scope = entry.scope,
    key = entry.key,
    category = entry.category,
    summary = entry.summary,
    uncertainty = entry.uncertainty,
    refs = entry.refs,
    protected = entry.protected,
    status = entry.status,
    author = entry.author,
    updated = os.date("%Y-%m-%d", math.floor((entry.updated_at or 0) / 1000)),
  }
  if include_content then
    out.content = entry.content
  end
  return out
end

---@param ctx table operation context
---@param args table
function M.list(ctx, args)
  local scope = args.scope or "all"
  if scope ~= "all" and scope ~= "global" and scope ~= "project" then
    return { ok = false, error = 'scope must be "all", "global", or "project"' }
  end
  local entries = memory.list(scope, ctx.project, args.include_deleted and "all" or "active")
  local out = {}
  for i = 1, math.min(#entries, LIST_LIMIT) do
    out[#out + 1] = describe(entries[i], true)
  end
  return {
    ok = true,
    entries = out,
    truncated = #entries > LIST_LIMIT and ("showing " .. LIST_LIMIT .. " of " .. #entries) or nil,
  }
end

---@param ctx table operation context
---@param args table
function M.search(ctx, args)
  local entries = memory.recall(ctx.project, { query = args.query })
  local out = {}
  for _, entry in ipairs(entries) do
    out[#out + 1] = describe(entry, true)
  end
  return { ok = true, entries = out }
end

local function split_refs(value)
  if value == nil then
    return nil
  end
  local out = {}
  for _, item in ipairs(vim.split(value, ",", { trimempty = true, plain = true })) do
    local ref = vim.trim(item)
    if ref ~= "" then
      out[#out + 1] = ref
    end
  end
  return #out > 0 and out or nil
end

---@param ctx table operation context
---@param args table
function M.remember(ctx, args)
  local result = memory.remember({
    project = ctx.project,
    scope = args.scope,
    category = args.category,
    summary = args.summary,
    content = args.content,
    uncertainty = args.uncertainty,
    refs = split_refs(args.refs),
    key = args.key,
    author = "agent",
  })
  if result.ok then
    result.entry = describe(result.entry, false)
  end
  return result
end

---@param ctx table operation context
---@param args table
function M.update(ctx, args)
  local result = memory.update(math.floor(args.entry_id), "agent", math.floor(args.expected_revision), {
    summary = args.summary,
    content = args.content,
    category = args.category,
    uncertainty = args.uncertainty,
    refs = split_refs(args.refs),
  }, args.reason)
  if result.ok then
    result.entry = describe(result.entry, false)
  end
  return result
end

---@param ctx table operation context
---@param args table
function M.delete(ctx, args)
  local result =
    memory.delete_entry(math.floor(args.entry_id), "agent", math.floor(args.expected_revision), args.reason)
  if result.ok then
    result.entry = describe(result.entry, false)
  end
  return result
end

return M
