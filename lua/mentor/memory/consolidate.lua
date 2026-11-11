-- Bounded memory consolidation: merge redundant or outdated entries.
--
-- Deliberately manual for now: automatic scheduling is gated behind
-- Observer activation (a later milestone), but the job itself is fully
-- implemented and runs under the shared bounded agent loop with
-- background budgets. Protected (user-authored) entries and deletion
-- tombstones stay out of reach — they are excluded from candidates and the
-- memory tools refuse them regardless of what the model asks.

local config = require("mentor.config")
local memory = require("mentor.memory")
local prompts = require("mentor.prompts")

local M = {}

local CONSOLIDATION_TOOLS =
  { "memory_list", "memory_search", "memory_remember", "memory_update", "memory_delete" }

local active = nil

---Deterministic candidate grouping: unprotected active entries in the same
---category cluster when their summaries or refs plausibly overlap. Only
---clusters of two or more entries are consolidation candidates.
---@param entries mentor.MemoryEntry[]
---@return table[] groups
local function candidate_groups(entries)
  local cfg = config.get().memory
  local pool = {}
  for _, e in ipairs(entries) do
    if not e.protected then
      pool[#pool + 1] = e
      if #pool >= cfg.consolidate_max_entries then
        break
      end
    end
  end

  local function tokens(text)
    local out = {}
    for word in (text or ""):lower():gmatch("[%w_']+") do
      if #word >= 3 then
        out[word] = true
      end
    end
    return out
  end

  local function overlap(a, b)
    local n = 0
    for word in pairs(a) do
      if b[word] then
        n = n + 1
      end
    end
    return n
  end

  -- Union-find over candidate pairs.
  local parent = {}
  for i = 1, #pool do
    parent[i] = i
  end
  local function find(i)
    while parent[i] ~= i do
      i = parent[i]
    end
    return i
  end
  local function union(a, b)
    parent[find(a)] = find(b)
  end

  local summary_tokens, ref_sets = {}, {}
  for i, e in ipairs(pool) do
    summary_tokens[i] = tokens(e.summary .. " " .. e.key)
    ref_sets[i] = {}
    for _, ref in ipairs(e.refs or {}) do
      ref_sets[i][ref:lower()] = true
    end
  end
  for i = 1, #pool do
    for j = i + 1, #pool do
      if pool[i].category == pool[j].category then
        local same = overlap(ref_sets[i], ref_sets[j]) > 0
          or pool[i].summary:lower() == pool[j].summary:lower()
          or overlap(summary_tokens[i], summary_tokens[j]) >= 2
        if same then
          union(i, j)
        end
      end
    end
  end

  local by_root = {}
  for i, e in ipairs(pool) do
    local root = find(i)
    by_root[root] = by_root[root] or {}
    by_root[root][#by_root[root] + 1] = e
  end
  local groups = {}
  for _, group in pairs(by_root) do
    if #group >= 2 then
      groups[#groups + 1] = group
    end
  end
  table.sort(groups, function(a, b)
    return a[1].updated_at > b[1].updated_at
  end)
  return groups
end

local function render_groups(groups)
  local lines = {}
  for gi, group in ipairs(groups) do
    lines[#lines + 1] = "Group " .. gi .. ":"
    for _, e in ipairs(group) do
      local refs = e.refs and (" refs: " .. table.concat(e.refs, ", ")) or ""
      local content = e.content:gsub("[\r\n]+", " ")
      if #content > 500 then
        content = content:sub(1, 500) .. " [truncated]"
      end
      lines[#lines + 1] = string.format(
        "- [m%d r%d · %s · %s] %s%s%s",
        e.id,
        e.revision,
        e.category,
        e.uncertainty,
        e.summary,
        content ~= "" and (": " .. content) or "",
        refs
      )
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

---Run one bounded consolidation pass for a project.
---@param proj mentor.Project
---@param callbacks table|nil { on_note = fun(string), on_done = fun(err|nil, info) }
---@return table|nil handle, string|nil actionable error
function M.run(proj, callbacks)
  if active then
    return nil, "mentor.nvim: a consolidation pass is already running"
  end
  callbacks = callbacks or {}
  local entries = memory.visible(proj)
  local groups = candidate_groups(entries)
  if #groups == 0 then
    return nil, "mentor.nvim: no redundant memory entries to consider"
  end

  local messages = {
    { role = "system", content = prompts.consolidation_system(render_groups(groups)) },
    { role = "user", content = "Consolidate the redundant entries listed." },
  }
  local handle, run_err = require("mentor.agent").run({
    mode = "coach",
    kind = "background",
    project = proj,
    messages = messages,
    tools = CONSOLIDATION_TOOLS,
    on_note = callbacks.on_note,
    on_tool = callbacks.on_tool,
    on_done = function(err, info)
      active = nil
      if callbacks.on_done then
        callbacks.on_done(err, info)
      end
    end,
  })
  if not handle then
    return nil, run_err
  end
  active = handle
  return handle
end

---Cancel the running consolidation pass (wired to :MentorStop).
---@return integer cancelled count
function M.stop()
  if active and active:is_active() then
    active:cancel()
    return 1
  end
  return 0
end

function M.active_count()
  return active and active:is_active() and 1 or 0
end

return M
