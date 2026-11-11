-- Persistent memory: global and project-scoped entries the assistant can
-- create and revise, with strict user control on top:
--
--   * Optimistic concurrency: every mutation carries an expected revision;
--     a stale write (another Neovim instance got there first) is rejected,
--     never silently merged.
--   * Inspectable history: every change appends a full snapshot; revert
--     re-applies a snapshot as a new revision.
--   * User precedence: user edits mark entries protected; protected entries
--     are immune to agent updates, deletion, and consolidation until the user
--     releases protection. The agent may only propose a separate entry.
--   * Deletion is reversible (tombstone) and suppresses automatic
--     recreation while it exists; permanent erasure removes the entry and
--     all revisions, leaving only a content-free audit marker. Chat material
--     is independent and cleared separately.
--   * Provenance is rechecked: entries referencing paths that the current
--     access policy excludes are withheld from retrieval and from replayed
--     tool results, never silently retransmitted.
--   * Writes are sanitized: detected secrets never enter storage.
--
-- Everything returns structured results ({ok, ...} / {ok=false, error});
-- callers never build queries and nothing here throws.

local records = require("mentor.storage.records")
local storage = require("mentor.storage")
local policy_mod = require("mentor.policy")
local sanitize = require("mentor.sanitize")
local config = require("mentor.config")

local M = {}

local MAX_SUMMARY = 200
local MAX_CONTENT = 8192
local MAX_REFS = 32
local MAX_REF_BYTES = 300
local UNCERTAINTY = { established = true, hypothesis = true }

---@class mentor.MemoryEntry
---@field id integer
---@field revision integer
---@field scope "global"|"project"
---@field project_id integer|nil
---@field key string
---@field category string
---@field summary string
---@field content string
---@field uncertainty "established"|"hypothesis"
---@field refs string[]|nil
---@field protected boolean
---@field status "active"|"deleted"
---@field author string
---@field created_at integer
---@field updated_at integer

---@param proj mentor.Project
---@return integer
local function project_row_id(proj)
  return records.projects.touch({
    identity = proj.identity,
    root = proj.root,
    is_git = proj.is_git,
    git_common_dir = proj.git_common_dir,
  })
end

---@param text string
---@return string slug usable as an entry key
function M.slug(text)
  local s = (text or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if #s > 48 then
    s = s:sub(1, 48):gsub("%-+$", "")
  end
  return s
end

local function decode_refs(json_str)
  if json_str == nil or json_str == "" then
    return nil
  end
  local ok, refs = pcall(vim.json.decode, json_str)
  if ok and type(refs) == "table" and #refs > 0 then
    return refs
  end
  return nil
end

---@param row table memory_entry row
---@return mentor.MemoryEntry
local function normalize(row)
  return {
    id = row.id,
    revision = row.revision,
    scope = row.scope,
    project_id = row.project_id,
    key = row.entry_key,
    category = row.category,
    summary = row.summary,
    content = row.content or "",
    uncertainty = row.uncertainty,
    refs = decode_refs(row.refs),
    protected = row.protected == 1,
    status = row.status,
    author = row.author,
    created_at = row.created_at,
    updated_at = row.updated_at,
  }
end

M.normalize = normalize

---A ref counts as a path when it looks like one; bare concepts are never
---path-authorized (and never withheld on provenance grounds).
---@param ref string
---@return boolean
local function pathlike(ref)
  if type(ref) ~= "string" then
    return false
  end
  return ref:find("/") ~= nil or ref:match("^[%w_%-%.]+%.[%w]+$") ~= nil
end

---True when any path-like provenance ref is currently excluded for proj.
local function provenance_excluded(entry, proj)
  if entry.refs == nil then
    return false
  end
  local pol = policy_mod.for_project(proj)
  for _, ref in ipairs(entry.refs) do
    if pathlike(ref) then
      local _, why = pol:authorize(ref)
      if why then
        return true
      end
    end
  end
  return false
end

M.pathlike = pathlike

---Sanitize and validate writable fields; returns the clean values or a list
---of problems. Secrets are redacted (recorded in findings), not rejected: a
---note that happened to quote a credential stays useful minus the credential.
---@param fields table {summary, content, category, uncertainty, refs}
---@param require_summary boolean
---@return table|nil clean, string[]|nil problems, table[]|nil redactions
local function clean_fields(fields, require_summary)
  local problems = {}
  local findings = {}
  local clean = sanitize.sanitize_tree({
    summary = fields.summary,
    content = fields.content,
    refs = fields.refs,
  }, findings)
  if require_summary then
    if type(clean.summary) ~= "string" or clean.summary == "" then
      problems[#problems + 1] = "summary must be a non-empty string"
    end
    if clean.summary and #clean.summary > MAX_SUMMARY then
      problems[#problems + 1] = "summary exceeds " .. MAX_SUMMARY .. " bytes"
    end
  end
  if clean.summary == nil then
    clean.summary = nil
  end
  if clean.content ~= nil and (type(clean.content) ~= "string" or #clean.content > MAX_CONTENT) then
    problems[#problems + 1] = "content must be a string within " .. MAX_CONTENT .. " bytes"
  end
  if clean.refs ~= nil then
    if type(clean.refs) ~= "table" then
      problems[#problems + 1] = "refs must be a list of paths/concepts"
    else
      if #clean.refs > MAX_REFS then
        problems[#problems + 1] = "refs exceeds " .. MAX_REFS .. " items"
      end
      for i, ref in ipairs(clean.refs) do
        if type(ref) ~= "string" or ref == "" or #ref > MAX_REF_BYTES then
          problems[#problems + 1] = "ref " .. i .. " must be a string within " .. MAX_REF_BYTES .. " bytes"
        end
      end
    end
  end
  if #problems > 0 then
    return nil, problems, #findings > 0 and findings or nil
  end
  return clean, nil, #findings > 0 and findings or nil
end

local function check_category(category, problems)
  if category == nil then
    return "note"
  end
  if type(category) ~= "string" or #category > 64 or not category:match("^[%w][%w_%-%. ]*$") then
    problems[#problems + 1] = 'category must be a short word like "preference" or "decision"'
    return nil
  end
  return category
end

---@class mentor.MemoryRemember
---@field project mentor.Project|nil required for project scope
---@field scope "global"|"project"
---@field category string|nil
---@field summary string
---@field content string|nil
---@field uncertainty "established"|"hypothesis"|nil defaults to hypothesis
---@field refs string[]|nil
---@field key string|nil explicit slug; derived from the summary when absent
---@field author "user"|"agent"
---@field protected boolean|nil user-authored writes are protected

---Create an entry. Agent writes are refused while a user-deleted tombstone
---with the same key exists (deleted entries stay suppressed).
---@param req mentor.MemoryRemember
---@return table {ok, entry}|{ok=false, error}
function M.remember(req)
  if req.scope ~= "global" and req.scope ~= "project" then
    return { ok = false, error = 'scope must be "global" or "project"' }
  end
  local pid = nil
  if req.scope == "project" then
    if not req.project then
      return { ok = false, error = "project scope requires project context" }
    end
    pid = project_row_id(req.project)
  end
  local clean, problems, redactions = clean_fields(req, true)
  if not clean then
    return { ok = false, error = "invalid entry: " .. table.concat(problems, "; ") }
  end
  local category_problems = {}
  local category = check_category(req.category, category_problems)
  if #category_problems > 0 then
    return { ok = false, error = "invalid entry: " .. category_problems[1] }
  end
  local uncertainty = req.uncertainty or "hypothesis"
  if not UNCERTAINTY[uncertainty] then
    return { ok = false, error = 'uncertainty must be "established" or "hypothesis"' }
  end
  local key = req.key and M.slug(req.key) or M.slug(clean.summary)
  if key == "" then
    key = "entry"
  end

  local existing = records.memory.find_by_key(req.scope, pid, key)
  if existing then
    if existing.status == "active" then
      return {
        ok = false,
        error = "an active entry with key '"
          .. key
          .. "' already exists (m"
          .. existing.id
          .. "); update it instead",
      }
    end
    if req.author == "agent" then
      return {
        ok = false,
        error = "entry '"
          .. key
          .. "' (m"
          .. existing.id
          .. ") was deleted by the user and stays suppressed; if this correction matters, record it as a separate entry",
      }
    end
  end

  local id = records.memory.insert({
    scope = req.scope,
    project_id = pid,
    entry_key = key,
    category = category,
    summary = clean.summary,
    content = clean.content or "",
    uncertainty = uncertainty,
    refs = clean.refs,
    protected = req.protected or (req.author == "user") or false,
    author = req.author,
  })
  local result = { ok = true, entry = normalize(records.memory.get(id)) }
  if redactions then
    result.redacted = #redactions
  end
  return result
end

---Shared write path for update/delete/restore: fetch, actor/status/revision
---guards. Returns (row, error_message).
local function writable(id, actor, expected_revision)
  local row = records.memory.get(id)
  if not row then
    return nil, "memory entry m" .. id .. " does not exist (it may have been erased)"
  end
  if actor == "agent" then
    if row.protected == 1 then
      return nil,
        "m"
          .. id
          .. " is protected by a user edit: the user's version takes precedence. Record a separate entry with your supporting evidence instead, and the user can reconcile them"
    end
    if row.status == "deleted" then
      return nil, "m" .. id .. " was deleted by the user and stays suppressed"
    end
  end
  if expected_revision ~= nil and row.revision ~= expected_revision then
    return nil,
      "m"
        .. id
        .. " changed since your view (you saw revision "
        .. expected_revision
        .. ", it is now "
        .. row.revision
        .. "); re-read it before writing"
  end
  return row, nil
end

---Apply a partial update at expected_revision; appends a history snapshot.
---@param id integer
---@param actor "user"|"agent"
---@param expected_revision integer
---@param fields table any of summary, content, category, uncertainty, refs
---@param reason string|nil
---@return table {ok, entry}|{ok=false, error}
function M.update(id, actor, expected_revision, fields, reason)
  local row, err = writable(id, actor, expected_revision)
  if not row then
    return { ok = false, error = err }
  end
  local clean, problems, redactions = clean_fields(fields, false)
  if not clean then
    return { ok = false, error = "invalid entry: " .. table.concat(problems, "; ") }
  end
  local category_problems = {}
  local category = fields.category and check_category(fields.category, category_problems) or row.category
  if #category_problems > 0 then
    return { ok = false, error = "invalid entry: " .. category_problems[1] }
  end
  local uncertainty = fields.uncertainty or row.uncertainty
  if not UNCERTAINTY[uncertainty] then
    return { ok = false, error = 'uncertainty must be "established" or "hypothesis"' }
  end
  local snap = {
    category = category,
    summary = clean.summary or row.summary,
    content = clean.content ~= nil and clean.content or row.content,
    uncertainty = uncertainty,
    refs = clean.refs ~= nil and clean.refs or decode_refs(row.refs),
  }
  -- User edits take precedence over model inferences: a user write protects
  -- the entry against agent replacement until the user releases it.
  local opts = actor == "user" and { protected = true } or nil
  local affected = records.memory.update(id, row.revision, snap, actor, reason, opts)
  if affected == 0 then
    local now = records.memory.get(id)
    return {
      ok = false,
      error = "m"
        .. id
        .. " changed concurrently (now revision "
        .. (now and now.revision or "?")
        .. "); re-read before writing",
    }
  end
  records.memory.append_revision(id, row.revision + 1, snap, actor, reason)
  local result = { ok = true, entry = normalize(records.memory.get(id)) }
  if redactions then
    result.redacted = #redactions
  end
  return result
end

---Reversible deletion: keeps a tombstone that suppresses automatic
---recreation, and history that makes restore possible.
function M.delete_entry(id, actor, expected_revision, reason)
  local row, err = writable(id, actor, expected_revision)
  if not row then
    return { ok = false, error = err }
  end
  if row.status == "deleted" then
    return { ok = true, entry = normalize(row), already = true }
  end
  local snap = {
    category = row.category,
    summary = row.summary,
    content = row.content,
    uncertainty = row.uncertainty,
    refs = decode_refs(row.refs),
  }
  local affected =
    records.memory.update(id, row.revision, snap, actor, reason or "deleted", { status = "deleted" })
  if affected == 0 then
    return { ok = false, error = "m" .. id .. " changed concurrently; re-read before writing" }
  end
  records.memory.append_revision(id, row.revision + 1, snap, actor, reason or "deleted")
  return { ok = true, entry = normalize(records.memory.get(id)) }
end

---Restore a tombstone (user path; revert covers "undo the deletion").
function M.restore(id, actor, expected_revision)
  local row, err = writable(id, actor, expected_revision)
  if not row then
    return { ok = false, error = err }
  end
  if row.status == "active" then
    return { ok = true, entry = normalize(row), already = true }
  end
  local snap = {
    category = row.category,
    summary = row.summary,
    content = row.content,
    uncertainty = row.uncertainty,
    refs = decode_refs(row.refs),
  }
  local affected = records.memory.update(id, row.revision, snap, actor, "restored", { status = "active" })
  if affected == 0 then
    return { ok = false, error = "m" .. id .. " changed concurrently; re-read before writing" }
  end
  records.memory.append_revision(id, row.revision + 1, snap, actor, "restored")
  return { ok = true, entry = normalize(records.memory.get(id)) }
end

---Re-apply an older history snapshot as a new revision (undo of an unwanted
---change, including a deletion).
---@param id integer
---@param to_revision integer
---@param actor "user"|"agent"
---@return table {ok, entry}|{ok=false, error}
function M.revert(id, to_revision, actor)
  local snap = records.memory.get_revision(id, to_revision)
  if not snap then
    return {
      ok = false,
      error = "no history snapshot at revision " .. tostring(to_revision) .. " for m" .. id,
    }
  end
  local row, err = writable(id, actor, nil)
  if not row then
    return { ok = false, error = err }
  end
  local new_snap = {
    category = snap.category,
    summary = snap.summary,
    content = snap.content,
    uncertainty = snap.uncertainty,
    refs = decode_refs(snap.refs),
  }
  local affected =
    records.memory.update(id, row.revision, new_snap, actor, "reverted to revision " .. to_revision, {
      status = "active",
      protected = true,
    })
  if affected == 0 then
    return { ok = false, error = "m" .. id .. " changed concurrently; run revert again" }
  end
  records.memory.append_revision(
    id,
    row.revision + 1,
    new_snap,
    actor,
    "reverted to revision " .. to_revision
  )
  return { ok = true, entry = normalize(records.memory.get(id)) }
end

---Permanent logical erasure: removes the entry and every revision snapshot,
---keeping only a content-free audit marker. Does NOT touch chat material
---(that is cleared through :MentorChatClear).
function M.erase(id)
  if not records.memory.get(id) then
    return { ok = false, error = "memory entry m" .. id .. " does not exist" }
  end
  records.memory.erase(id)
  return { ok = true, erased = id }
end

---Protection control (user only): releases or re-applies user precedence.
function M.set_protected(id, flag)
  if records.memory.set_protected(id, flag) == 0 then
    return { ok = false, error = "memory entry m" .. id .. " does not exist" }
  end
  records.memory.audit(id, flag and "protected" or "unprotected")
  return { ok = true, entry = normalize(records.memory.get(id)) }
end

function M.get(id)
  local row = records.memory.get(id)
  return row and normalize(row) or nil
end

---Entries visible to a project: its own plus global ones, never other
---projects' entries. Tombstones are excluded.
---@param proj mentor.Project
---@return mentor.MemoryEntry[]
function M.visible(proj)
  local out = {}
  for _, row in ipairs(records.memory.visible(project_row_id(proj))) do
    out[#out + 1] = normalize(row)
  end
  return out
end

---All entries for one scope including tombstones (view, audit listings).
function M.list(scope, proj, status)
  local pid = proj and project_row_id(proj) or nil
  local out = {}
  for _, row in ipairs(records.memory.list(scope, pid, status)) do
    out[#out + 1] = normalize(row)
  end
  return out
end

---Retrieve entries for a request: current-project + global, filtered to
---those whose path provenance is still authorized (a path that became
---excluded conservatively omits the whole entry), optional query filter,
---bounded. Entries are returned most-recently-updated first.
---@param proj mentor.Project
---@param opts table|nil { query = string, limit = integer }
---@return mentor.MemoryEntry[]
function M.recall(proj, opts)
  opts = opts or {}
  local cfg = config.get().memory
  local limit = opts.limit or cfg.recall_limit
  local query = opts.query and vim.pesc(vim.trim(opts.query):lower()) or nil
  local out = {}
  for _, entry in ipairs(M.visible(proj)) do
    local include = true
    if query then
      local haystack = (entry.summary .. " " .. entry.content .. " " .. table.concat(entry.refs or {}, " ")):lower()
      include = haystack:find(query, 1, true) ~= nil
    end
    if include and provenance_excluded(entry, proj) then
      include = false
    end
    if include then
      out[#out + 1] = entry
      if #out >= limit then
        break
      end
    end
  end
  return out
end

---Render the memory block injected into model requests; returns "" when
---there is nothing to inject. Bounded by memory.recall_max_bytes.
---@param proj mentor.Project
---@return string, integer count
function M.render_context(proj)
  local entries = M.recall(proj)
  if #entries == 0 then
    return "", 0
  end
  local cap = config.get().memory.recall_max_bytes
  local lines = {
    "Persistent memory (stored locally, user-inspectable via :MentorMemory;",
    "may be stale; the developer's current words always take precedence):",
  }
  local bytes = 0
  local used = 0
  for _, e in ipairs(entries) do
    local refs = e.refs and (" refs: " .. table.concat(e.refs, ", ")) or ""
    local line = string.format(
      "- [m%d · %s · %s · %s] %s%s%s",
      e.id,
      e.scope,
      e.category,
      e.uncertainty,
      e.summary,
      e.content ~= "" and (": " .. e.content:gsub("[\r\n]+", " ")) or "",
      refs
    )
    if bytes + #line + 1 > cap then
      lines[#lines + 1] = "- [more memory entries omitted: request budget]"
      break
    end
    bytes = bytes + #line + 1
    used = used + 1
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n"), used
end

---Re-authorize a serialized memory tool result against the current policy:
---any embedded entry whose path provenance is now excluded is replaced with
---a withheld marker instead of being replayed to the provider.
---@param serialized string tool result JSON
---@param proj mentor.Project
---@return string rewritten, boolean changed
function M.reauthorize_result(serialized, proj)
  if type(serialized) ~= "string" or serialized == "" then
    return serialized, false
  end
  local ok, decoded = pcall(vim.json.decode, serialized)
  if not ok or type(decoded) ~= "table" then
    return serialized, false
  end
  local changed = false
  local function walk(node, seen)
    if type(node) ~= "table" or seen[node] then
      return
    end
    seen[node] = true
    if node.id ~= nil and node.content ~= nil and node.refs ~= nil and node.withheld ~= true then
      local entry = normalize({
        id = node.id,
        revision = node.revision or 1,
        scope = node.scope or "project",
        project_id = node.project_id,
        entry_key = node.key or "",
        category = node.category or "",
        summary = node.summary or "",
        content = node.content,
        uncertainty = node.uncertainty or "established",
        refs = vim.json.encode(node.refs),
        protected = node.protected and 1 or 0,
        status = node.status or "active",
        author = node.author or "",
        created_at = 0,
        updated_at = 0,
      })
      if provenance_excluded(entry, proj) then
        node.content = ""
        node.summary = "[entry withheld: its source is excluded by the current access policy]"
        node.refs = {}
        node.withheld = true
        changed = true
      end
    end
    for _, child in pairs(node) do
      walk(child, seen)
    end
  end
  walk(decoded, {})
  if not changed then
    return serialized, false
  end
  return vim.json.encode(decoded), true
end

---Apply a batch of view edits atomically: validate every piece first
---(existence + expected revisions), then commit updates, deletions, and
---creations in one transaction so a rejected piece rolls everything back.
---@param proj mentor.Project|nil context for created project-scope entries
---@param edits table { updates = {{id, expected_revision, summary, content, category, uncertainty, refs}}, creates = {mentor.MemoryRemember-ish}, deletes = {id} }
---@return table {ok} | {ok=false, problems=string[]}
function M.apply_view_edits(proj, edits)
  local problems = {}
  for _, u in ipairs(edits.updates or {}) do
    local row = records.memory.get(u.id)
    if not row then
      problems[#problems + 1] = "m"
        .. u.id
        .. " no longer exists (erased elsewhere?); your proposed text for it was kept in the buffer"
    elseif row.revision ~= u.expected_revision then
      problems[#problems + 1] = "m"
        .. u.id
        .. " changed since this view was rendered (you saw revision "
        .. u.expected_revision
        .. ", it is now "
        .. row.revision
        .. "); your text was kept — re-render and re-apply"
    end
  end
  for _, id in ipairs(edits.deletes or {}) do
    local row = records.memory.get(id)
    if not row then
      problems[#problems + 1] = "m" .. id .. " no longer exists; nothing to delete"
    end
  end
  if #problems > 0 then
    return { ok = false, problems = problems }
  end

  local tx_ok, tx_err = pcall(storage.transaction, function()
    for _, u in ipairs(edits.updates or {}) do
      local res = M.update(u.id, "user", u.expected_revision, {
        summary = u.summary,
        content = u.content,
        category = u.category,
        uncertainty = u.uncertainty,
        refs = u.refs,
      }, "edited in the memory view")
      if not res.ok then
        error("mentor.nvim memory: " .. res.error, 0)
      end
    end
    for _, id in ipairs(edits.deletes or {}) do
      local res = M.delete_entry(id, "user", nil, "removed in the memory view")
      if not res.ok then
        error("mentor.nvim memory: " .. res.error, 0)
      end
    end
    for _, c in ipairs(edits.creates or {}) do
      c.project = proj
      c.scope = c.scope or (proj and "project" or "global")
      c.author = "user"
      local res = M.remember(c)
      if not res.ok then
        error("mentor.nvim memory: " .. res.error, 0)
      end
    end
  end)
  if not tx_ok then
    local msg = tostring(tx_err)
    return { ok = false, problems = { msg:gsub("^[^:]*:%d*: ", "") } }
  end
  return { ok = true }
end

function M.counts(proj)
  return records.memory.counts(project_row_id(proj))
end

return M
