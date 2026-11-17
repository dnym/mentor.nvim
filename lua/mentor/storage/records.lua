-- Scoped repositories over the storage adapter. Callers never build
-- arbitrary queries against persisted entities; they go through these
-- parameterized methods that require an explicit scope.

local storage = require("mentor.storage")
local clock = require("mentor.clock")

local M = {}
local projects = {}
M.projects = projects

---@class mentor.ProjectRecord
---@field identity string canonical absolute working-tree root
---@field root string
---@field is_git boolean
---@field git_common_dir string|nil

---Returns the stored row id for a project, creating it on first use.
---@param rec mentor.ProjectRecord
---@return integer id
function projects.touch(rec)
  local row = storage.query("SELECT id FROM project WHERE identity = ?;", { rec.identity })[1]
  if row then
    return row.id
  end
  local _, id = storage.execute(
    "INSERT INTO project (identity, root, is_git, git_common_dir, created_at) VALUES (?, ?, ?, ?, ?);",
    { rec.identity, rec.root, rec.is_git, rec.git_common_dir, clock.now_ms() }
  )
  return id
end

---@param identity string
---@return table|nil row
function projects.get(identity)
  return storage.query("SELECT * FROM project WHERE identity = ?;", { identity })[1]
end

---@return integer
function projects.count()
  return storage.scalar("SELECT COUNT(*) FROM project;") or 0
end

-- Conversations: one linear transcript per (project, mode). Content is
-- sanitized before it reaches this layer; provenance rides along on tool
-- results so stored context can be rechecked against later policy changes.
local conversations = {}
M.conversations = conversations

---@class mentor.ChatMessage
---@field role "user"|"assistant"|"tool"
---@field content string
---@field tool_calls string[]|table[]|nil assistant messages: OpenAI tool calls
---@field tool_call_id string|nil tool messages: call this result answers
---@field source string|nil tool messages: provenance path of the result
---@field tool string|nil tool messages: producing tool name (recheck by kind)

---@param project_id integer
---@param mode string
---@param msg mentor.ChatMessage
---@return integer row id
function conversations.append(project_id, mode, msg)
  local tool_calls = nil
  if msg.tool_calls ~= nil then
    tool_calls = type(msg.tool_calls) == "string" and msg.tool_calls or vim.json.encode(msg.tool_calls)
  end
  local _, id = storage.execute(
    "INSERT INTO chat_message (project_id, mode, role, content, tool_calls, tool_call_id, source, tool, created_at)"
      .. " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);",
    {
      project_id,
      mode,
      msg.role,
      msg.content or "",
      tool_calls,
      msg.tool_call_id,
      msg.source,
      msg.tool,
      clock.now_ms(),
    }
  )
  return id
end

---Messages oldest-first, optionally capped to the newest `limit` rows.
---@param project_id integer
---@param mode string
---@param limit integer|nil
---@return mentor.ChatMessage[] rows with id and created_at included
function conversations.load(project_id, mode, limit)
  local sql = "SELECT id, role, content, tool_calls, tool_call_id, source, tool, created_at"
    .. " FROM chat_message WHERE project_id = ? AND mode = ?"
  if limit then
    sql = sql .. " ORDER BY id DESC LIMIT ?;"
  else
    sql = sql .. " ORDER BY id ASC;"
  end
  local params = limit and { project_id, mode, limit } or { project_id, mode }
  local rows = storage.query(sql, params)
  if limit then
    local reversed = {}
    for i = #rows, 1, -1 do
      reversed[#reversed + 1] = rows[i]
    end
    return reversed
  end
  return rows
end

---@param project_id integer
---@param mode string
---@return integer
function conversations.count(project_id, mode)
  return storage.scalar("SELECT COUNT(*) FROM chat_message WHERE project_id = ? AND mode = ?;", {
    project_id,
    mode,
  }) or 0
end

---Explicit clearing of a conversation (memory erasure does NOT do this:
---chat material is independently retained and cleared separately).
---@param project_id integer
---@param mode string
---@return integer removed
function conversations.delete_all(project_id, mode)
  return storage.execute("DELETE FROM chat_message WHERE project_id = ? AND mode = ?;", { project_id, mode })
    or 0
end

-- Persistent memory. Entries are global or project-scoped; every change
-- appends a snapshot to the revision history. These methods only move rows;
-- policy (protection, revision conflicts, sanitization, deletion
-- suppression) lives in the memory module above them.
local memory = {}
M.memory = memory

---@class mentor.MemoryInsert
---@field scope "global"|"project"
---@field project_id integer|nil
---@field entry_key string
---@field category string
---@field summary string
---@field content string
---@field uncertainty "established"|"hypothesis"
---@field refs string|table|nil JSON string or list
---@field protected boolean|nil
---@field author "user"|"agent"

local function encode_refs(refs)
  if refs == nil then
    return nil
  end
  return type(refs) == "string" and refs or vim.json.encode(refs)
end

---@param e mentor.MemoryInsert
---@return integer entry id
function memory.insert(e)
  local now = clock.now_ms()
  local _, id = storage.execute(
    "INSERT INTO memory_entry (scope, project_id, entry_key, category, summary, content, uncertainty, refs,"
      .. " status, protected, revision, author, created_at, updated_at)"
      .. " VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, 1, ?, ?, ?);",
    {
      e.scope,
      e.project_id,
      e.entry_key,
      e.category,
      e.summary,
      e.content or "",
      e.uncertainty or "established",
      encode_refs(e.refs),
      e.protected and 1 or 0,
      e.author,
      now,
      now,
    }
  )
  memory.append_revision(id, 1, e, e.author, "created")
  return id
end

---History snapshot for one revision of an entry (or entry-like table).
---@param entry_id integer
---@param revision integer
---@param snap table fields: category, summary, content, uncertainty, refs
---@param author string
---@param reason string|nil
function memory.append_revision(entry_id, revision, snap, author, reason)
  storage.execute(
    "INSERT INTO memory_revision (entry_id, revision, category, summary, content, uncertainty, refs, author,"
      .. " reason, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
    {
      entry_id,
      revision,
      snap.category,
      snap.summary,
      snap.content or "",
      snap.uncertainty or "established",
      encode_refs(snap.refs),
      author,
      reason,
      clock.now_ms(),
    }
  )
end

---@param id integer
---@return table|nil row
function memory.get(id)
  return storage.query("SELECT * FROM memory_entry WHERE id = ?;", { id })[1]
end

---@param scope string
---@param project_id integer|nil
---@param entry_key string
---@return table|nil row
function memory.find_by_key(scope, project_id, entry_key)
  if project_id == nil then
    return storage.query(
      "SELECT * FROM memory_entry WHERE scope = ? AND project_id IS NULL AND entry_key = ?;",
      { scope }
    )[1]
  end
  return storage.query(
    "SELECT * FROM memory_entry WHERE scope = ? AND project_id = ? AND entry_key = ?;",
    { scope, project_id, entry_key }
  )[1]
end

---Content-changing update guarded by the expected revision (optimistic
---concurrency across Neovim instances). Returns 0 on a stale write.
---@param id integer
---@param expected_revision integer
---@param snap table category, summary, content, uncertainty, refs
---@param author string
---@param reason string|nil
---@param opts table|nil { status = "active"|"deleted", protected = boolean|nil (keep when nil) }
---@return integer affected (0 = revision conflict)
function memory.update(id, expected_revision, snap, author, reason, opts)
  opts = opts or {}
  local status = opts.status or "active"
  local head = "UPDATE memory_entry SET category = ?, summary = ?, content = ?, uncertainty = ?, refs = ?,"
  local tail =
    " status = ?, author = ?, revision = revision + 1, updated_at = ? WHERE id = ? AND revision = ?;"
  local sql, params
  if opts.protected == nil then
    sql = head .. " " .. tail
    params =
      { snap.category, snap.summary, snap.content or "", snap.uncertainty, encode_refs(snap.refs), status }
  else
    sql = head .. " protected = ?, " .. tail
    params = {
      snap.category,
      snap.summary,
      snap.content or "",
      snap.uncertainty,
      encode_refs(snap.refs),
      opts.protected and 1 or 0,
      status,
    }
  end
  local now = clock.now_ms()
  params[#params + 1] = author
  params[#params + 1] = now
  params[#params + 1] = id
  params[#params + 1] = expected_revision
  return storage.execute(sql, params) or 0
end

---@param id integer
---@param protected boolean
---@return integer affected
function memory.set_protected(id, protected)
  return storage.execute("UPDATE memory_entry SET protected = ? WHERE id = ?;", { protected and 1 or 0, id })
    or 0
end

---@param id integer
---@return integer affected
function memory.touch_updated(id)
  return storage.execute("UPDATE memory_entry SET updated_at = ? WHERE id = ?;", { clock.now_ms(), id }) or 0
end

---@param entry_id integer
---@return table[] newest-first revision snapshots
function memory.list_revisions(entry_id)
  return storage.query(
    "SELECT revision, category, summary, content, uncertainty, refs, author, reason, created_at"
      .. " FROM memory_revision WHERE entry_id = ? ORDER BY revision DESC;",
    { entry_id }
  )
end

---@param entry_id integer
---@param revision integer
---@return table|nil
function memory.get_revision(entry_id, revision)
  return storage.query(
    "SELECT revision, category, summary, content, uncertainty, refs, author, reason, created_at"
      .. " FROM memory_revision WHERE entry_id = ? AND revision = ?;",
    { entry_id, revision }
  )[1]
end

---Active entries visible to one project: global plus that project's own.
---Never returns other projects' entries.
---@param project_id integer
---@param limit integer|nil
---@return table[] rows
function memory.visible(project_id, limit)
  local sql = "SELECT * FROM memory_entry WHERE status = 'active'"
    .. " AND (scope = 'global' OR (scope = 'project' AND project_id = ?)) ORDER BY updated_at DESC"
  local params = { project_id }
  if limit then
    sql = sql .. " LIMIT ?;"
    params[#params + 1] = limit
  else
    sql = sql .. ";"
  end
  return storage.query(sql, params)
end

---@param scope "global"|"project"|"all"
---@param project_id integer|nil
---@param status "active"|"deleted"|"all"|nil defaults to active
---@return table[] rows newest-first
function memory.list(scope, project_id, status)
  status = status or "active"
  local where, params = {}, {}
  if scope == "global" then
    where[#where + 1] = "scope = 'global'"
  elseif scope == "project" then
    where[#where + 1] = "scope = 'project' AND project_id = ?"
    params[#params + 1] = project_id
  else
    -- "all" always means one project's horizon: its own entries plus global
    -- ones, never another project's entries.
    where[#where + 1] = "(scope = 'global' OR (scope = 'project' AND project_id = ?))"
    params[#params + 1] = project_id
  end
  if status == "active" or status == "deleted" then
    where[#where + 1] = "status = ?"
    params[#params + 1] = status
  end
  local sql = "SELECT * FROM memory_entry"
  if #where > 0 then
    sql = sql .. " WHERE " .. table.concat(where, " AND ")
  end
  return storage.query(sql .. " ORDER BY updated_at DESC;", params)
end

---Erasure: removes the entry and every revision snapshot; keeps only a
---content-free audit marker (and clears nothing else: chat material is
---cleared through its own explicit path).
---@param id integer
function memory.erase(id)
  local row = memory.get(id)
  if not row then
    return
  end
  storage.transaction(function()
    storage.execute("DELETE FROM memory_revision WHERE entry_id = ?;", { id })
    storage.execute("DELETE FROM memory_entry WHERE id = ?;", { id })
    storage.execute(
      "INSERT INTO memory_audit (entry_id, scope, project_id, entry_key, action, created_at)"
        .. " VALUES (?, ?, ?, ?, 'erased', ?);",
      { id, row.scope, row.project_id, row.entry_key, clock.now_ms() }
    )
  end)
end

---@param entry_id integer
---@param action string
function memory.audit(entry_id, action)
  local row = memory.get(entry_id)
  if not row then
    return
  end
  storage.execute(
    "INSERT INTO memory_audit (entry_id, scope, project_id, entry_key, action, created_at) VALUES (?, ?, ?, ?, ?, ?);",
    { entry_id, row.scope, row.project_id, row.entry_key, action, clock.now_ms() }
  )
end

---@param project_id integer
---@return table { global, project, protected, deleted } counts
function memory.counts(project_id)
  return {
    global = storage.scalar(
      "SELECT COUNT(*) FROM memory_entry WHERE scope = 'global' AND status = 'active';"
    ) or 0,
    project = storage.scalar(
      "SELECT COUNT(*) FROM memory_entry WHERE scope = 'project' AND project_id = ? AND status = 'active';",
      { project_id }
    ) or 0,
    protected = storage.scalar(
      "SELECT COUNT(*) FROM memory_entry WHERE protected = 1 AND (scope = 'global' OR project_id = ?)"
        .. " AND status = 'active';",
      { project_id }
    ) or 0,
    deleted = storage.scalar(
      "SELECT COUNT(*) FROM memory_entry WHERE status = 'deleted'"
        .. " AND (scope = 'global' OR (scope = 'project' AND project_id = ?));",
      { project_id }
    ) or 0,
  }
end

-- Usage accounting. A model request first reserves budget atomically; the
-- reservation is marked dispatched when it actually reaches the transport,
-- then folded into daily totals with the real usage. A reservation known not
-- to have been dispatched can be released; a dispatched one can never be
-- undone, only retained conservatively, so a crash cannot make a spent
-- request invisible to budget checks.
local usage = {}
M.usage = usage

---@return string local calendar day (YYYY-MM-DD)
function usage.today()
  return os.date("%Y-%m-%d")
end

---@param project_id integer
---@param day string
---@param kind "interactive"|"background"
---@param model_requests integer
---@param est_tokens integer
---@return integer reservation id
function usage.reserve(project_id, day, kind, model_requests, est_tokens)
  local _, id = storage.execute(
    "INSERT INTO usage_reservation (project_id, day, kind, model_requests, est_tokens, state, created_at)"
      .. " VALUES (?, ?, ?, ?, ?, 'pending', ?);",
    { project_id, day, kind, model_requests, est_tokens, clock.now_ms() }
  )
  return id
end

---The request has reached the transport: conservative retention starts here.
---@param reservation_id integer
function usage.mark_dispatched(reservation_id)
  storage.execute("UPDATE usage_reservation SET state = 'dispatched' WHERE id = ?;", { reservation_id })
end

---Folds a settled request into daily totals at its real usage.
---@param reservation_id integer
---@param est_tokens integer total estimated tokens for the request (input + output)
---@param reported_input integer|nil provider-reported input tokens
---@param reported_output integer|nil provider-reported output tokens
function usage.commit_actual(reservation_id, est_tokens, reported_input, reported_output)
  storage.transaction(function()
    local row =
      storage.query("SELECT project_id, day, kind, model_requests FROM usage_reservation WHERE id = ?;", {
        reservation_id,
      })[1]
    if not row then
      return
    end
    storage.execute(
      "INSERT INTO usage_day (project_id, day, kind, model_requests, est_tokens, reported_input, reported_output)"
        .. " VALUES (?, ?, ?, ?, ?, ?, ?)"
        .. " ON CONFLICT (project_id, day, kind) DO UPDATE SET"
        .. " model_requests = model_requests + excluded.model_requests,"
        .. " est_tokens = est_tokens + excluded.est_tokens,"
        .. " reported_input = reported_input + excluded.reported_input,"
        .. " reported_output = reported_output + excluded.reported_output;",
      {
        row.project_id,
        row.day,
        row.kind,
        row.model_requests,
        est_tokens,
        reported_input or 0,
        reported_output or 0,
      }
    )
    storage.execute("DELETE FROM usage_reservation WHERE id = ?;", { reservation_id })
  end)
end

---Removes a reservation only when it is still pending (never dispatched).
---@param reservation_id integer
---@return boolean released
function usage.release(reservation_id)
  local affected =
    storage.execute("DELETE FROM usage_reservation WHERE id = ? AND state = 'pending';", { reservation_id })
  return (affected or 0) > 0
end

---Committed totals plus open reservations for one accounting scope.
---@param project_id integer
---@param day string
---@param kind "interactive"|"background"
---@return table {model_requests, est_tokens, reported_input, reported_output, open_reservations}
function usage.totals(project_id, day, kind)
  local day_row = storage.query(
    "SELECT model_requests, est_tokens, reported_input, reported_output FROM usage_day"
      .. " WHERE project_id = ? AND day = ? AND kind = ?;",
    { project_id, day, kind }
  )[1]
  local open = storage.query(
    "SELECT model_requests, est_tokens FROM usage_reservation WHERE project_id = ? AND day = ? AND kind = ?;",
    { project_id, day, kind }
  )
  local totals = {
    model_requests = (day_row and day_row.model_requests or 0),
    est_tokens = (day_row and day_row.est_tokens or 0),
    reported_input = (day_row and day_row.reported_input or 0),
    reported_output = (day_row and day_row.reported_output or 0),
    open_reservations = #open,
  }
  for _, row in ipairs(open) do
    totals.model_requests = totals.model_requests + row.model_requests
    totals.est_tokens = totals.est_tokens + row.est_tokens
  end
  return totals
end

---Crash cleanup, run at startup: pending reservations that were never
---dispatched are expired; dispatched reservations older than `stale_ms` are
---folded into daily totals at their reserved values (conservative retention).
---@param stale_ms integer
---@return integer released, integer retained
function usage.sweep(stale_ms)
  local now = clock.now_ms()
  local released =
    storage.execute("DELETE FROM usage_reservation WHERE state = 'pending' AND created_at < ?;", {
      now - stale_ms,
    })
  local stale = storage.query(
    "SELECT id, project_id, day, kind, model_requests, est_tokens FROM usage_reservation"
      .. " WHERE state = 'dispatched' AND created_at < ?;",
    { now - stale_ms }
  )
  for _, row in ipairs(stale) do
    storage.transaction(function()
      storage.execute(
        "INSERT INTO usage_day (project_id, day, kind, model_requests, est_tokens, reported_input, reported_output)"
          .. " VALUES (?, ?, ?, ?, ?, 0, 0)"
          .. " ON CONFLICT (project_id, day, kind) DO UPDATE SET"
          .. " model_requests = model_requests + excluded.model_requests,"
          .. " est_tokens = est_tokens + excluded.est_tokens;",
        { row.project_id, row.day, row.kind, row.model_requests, row.est_tokens }
      )
      storage.execute("DELETE FROM usage_reservation WHERE id = ?;", { row.id })
    end)
  end
  return (released or 0), #stale
end

---Background load across all plugin instances for the daily/hourly gates:
---committed day totals plus in-flight reservations. Hourly counts consider
---reservations created inside the window (every in-flight reservation was
---created within the last few minutes in practice); the daily figure counts
---every open reservation conservatively.
---@param project_id integer
---@param day string
---@param window_ms integer
---@return table { requests_hour, est_tokens_day, requests_day }
function usage.window(project_id, day, window_ms)
  local now = clock.now_ms()
  local day_row = storage.query(
    "SELECT model_requests, est_tokens FROM usage_day WHERE project_id = ? AND day = ? AND kind = 'background';",
    { project_id, day }
  )[1]
  local open = storage.query(
    "SELECT model_requests, est_tokens, created_at FROM usage_reservation"
      .. " WHERE project_id = ? AND kind = 'background';",
    { project_id }
  )
  local out = {
    requests_hour = day_row and day_row.model_requests or 0,
    est_tokens_day = (day_row and day_row.est_tokens or 0),
    requests_day = day_row and day_row.model_requests or 0,
  }
  for _, row in ipairs(open) do
    out.est_tokens_day = out.est_tokens_day + row.est_tokens
    out.requests_day = out.requests_day + row.model_requests
    if now - row.created_at <= window_ms then
      out.requests_hour = out.requests_hour + row.model_requests
    end
  end
  return out
end

-- Observer: per-project activation and persisted findings.
local observer = {}
M.observer = observer

---@param project_id integer
---@return table|nil row { enabled, endpoint, consolidation_day }
function observer.state(project_id)
  return storage.query("SELECT * FROM observer_state WHERE project_id = ?;", { project_id })[1]
end

---Persisted enable/disable decision bound to the endpoint accepted at
---activation. Disabling overwrites the endpoint marker so an endpoint
---change always forces a fresh explicit activation.
---@param project_id integer
---@param enabled boolean
---@param endpoint string
function observer.set_enabled(project_id, enabled, endpoint)
  storage.execute(
    "INSERT INTO observer_state (project_id, enabled, endpoint, updated_at) VALUES (?, ?, ?, ?)"
      .. " ON CONFLICT (project_id) DO UPDATE SET"
      .. " enabled = excluded.enabled, endpoint = excluded.endpoint, updated_at = excluded.updated_at;",
    { project_id, enabled, enabled and endpoint or "", clock.now_ms() }
  )
end

---@param project_id integer
---@return string|nil day of the last scheduled consolidation pass
function observer.consolidation_day(project_id)
  local row = observer.state(project_id)
  return row and row.consolidation_day
end

---@param project_id integer
---@param day string
function observer.set_consolidation_day(project_id, day)
  storage.execute(
    "INSERT INTO observer_state (project_id, enabled, endpoint, consolidation_day, updated_at)"
      .. " VALUES (?, 0, '', ?, ?)"
      .. " ON CONFLICT (project_id) DO UPDATE SET consolidation_day = excluded.consolidation_day,"
      .. " updated_at = excluded.updated_at;",
    { project_id, day, clock.now_ms() }
  )
end

local observations = {}
M.observations = observations

---@class mentor.ObservationInsert
---@field project_id integer
---@field category string
---@field summary string
---@field reasoning string|nil
---@field certainty string
---@field refs string[]|nil
---@field fingerprints table|nil
---@field question string|nil
---@field issue_digest string
---@field stale boolean|nil

---@param o mentor.ObservationInsert
---@return integer id
function observations.insert(o)
  local _, id = storage.execute(
    "INSERT INTO observation (project_id, category, summary, reasoning, certainty, refs,"
      .. " fingerprints, question, issue_digest, dismissed, stale, created_at)"
      .. " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?);",
    {
      o.project_id,
      o.category,
      o.summary,
      o.reasoning or "",
      o.certainty,
      o.refs and vim.json.encode(o.refs) or nil,
      o.fingerprints and vim.json.encode(o.fingerprints) or nil,
      o.question or "",
      o.issue_digest,
      o.stale and 1 or 0,
      clock.now_ms(),
    }
  )
  return id
end

---@param id integer
---@return table|nil row
function observations.get(id)
  return storage.query("SELECT * FROM observation WHERE id = ?;", { id })[1]
end

---Active (non-dismissed) findings for dedup and cooldown checks.
---@param project_id integer
---@return table[] rows
function observations.list_active(project_id)
  return storage.query(
    "SELECT * FROM observation WHERE project_id = ? AND dismissed = 0 ORDER BY created_at DESC, id DESC;",
    { project_id }
  )
end

---Every finding for the list view, dismissed and stale included.
---@param project_id integer
---@param limit integer
---@return table[] rows
function observations.list_all(project_id, limit)
  return storage.query(
    "SELECT * FROM observation WHERE project_id = ? ORDER BY created_at DESC, id DESC LIMIT ?;",
    { project_id, limit }
  )
end

---@param project_id integer
---@return integer
function observations.count(project_id)
  return storage.scalar(
    "SELECT COUNT(*) FROM observation WHERE project_id = ? AND dismissed = 0;",
    { project_id }
  ) or 0
end

---Most recent finding with this dedup key (active or dismissed), used by
---the publication pipeline: an active match is a duplicate to drop, a
---dismissed match re-notifies only after the per-finding cooldown.
---@param project_id integer
---@param digest string
---@return table|nil row
function observations.latest_by_digest(project_id, digest)
  return storage.query(
    "SELECT * FROM observation WHERE project_id = ? AND issue_digest = ? ORDER BY created_at DESC, id DESC LIMIT 1;",
    { project_id, digest }
  )[1]
end

---@param project_id integer
---@return table { active, stale, dismissed, useful, not_useful }
function observations.counts(project_id)
  local function count(where, extra)
    local params = { project_id }
    for _, v in ipairs(extra or {}) do
      params[#params + 1] = v
    end
    return storage.scalar("SELECT COUNT(*) FROM observation WHERE project_id = ? AND " .. where, params) or 0
  end
  return {
    active = count("dismissed = 0"),
    stale = count("dismissed = 0 AND stale = 1"),
    dismissed = count("dismissed = 1"),
    useful = count("rating = 'useful'"),
    not_useful = count("rating = 'not-useful'"),
  }
end

---@param id integer
---@param notified_at integer|nil
function observations.mark_notified(id, notified_at)
  storage.execute("UPDATE observation SET notified_at = ?, notify_note = NULL WHERE id = ?;", {
    notified_at or clock.now_ms(),
    id,
  })
end

---Why the notification policy kept a finding quiet (nil clears it).
---@param id integer
---@param note string|nil
function observations.set_notify_note(id, note)
  storage.execute("UPDATE observation SET notify_note = ? WHERE id = ?;", { note, id })
end

---@param id integer
---@param dismissed boolean
function observations.set_dismissed(id, dismissed)
  storage.execute("UPDATE observation SET dismissed = ? WHERE id = ?;", {
    dismissed and 1 or 0,
    id,
  })
end

---@param id integer
---@param stale boolean
function observations.set_stale(id, stale)
  storage.execute("UPDATE observation SET stale = ? WHERE id = ?;", { stale and 1 or 0, id })
end

---@param id integer
---@param rating "useful"|"not-useful"|nil
function observations.set_rating(id, rating)
  storage.execute("UPDATE observation SET rating = ? WHERE id = ?;", { rating, id })
end

---@param project_id integer
---@return table[] rows { category, muted, snooze_until }
function observer.prefs(project_id)
  return storage.query("SELECT * FROM observation_pref WHERE project_id = ?;", { project_id })
end

---@param project_id integer
---@param category string
---@param muted boolean|nil nil leaves the current mute state untouched
---@param snooze_until integer|nil nil leaves the current snooze untouched
function observer.set_pref(project_id, category, muted, snooze_until)
  storage.execute(
    "INSERT INTO observation_pref (project_id, category, muted, snooze_until, updated_at)"
      .. " VALUES (?, ?, ?, ?, ?)"
      .. " ON CONFLICT (project_id, category) DO UPDATE SET"
      .. " muted = COALESCE(excluded.muted, observation_pref.muted),"
      .. " snooze_until = COALESCE(excluded.snooze_until, observation_pref.snooze_until),"
      .. " updated_at = excluded.updated_at;",
    {
      project_id,
      category,
      muted == nil and nil or (muted and 1 or 0),
      snooze_until,
      clock.now_ms(),
    }
  )
end

return M
