-- Scoped repositories over the storage adapter. Callers never build
-- arbitrary queries against persisted entities; they go through these
-- parameterized methods that require an explicit scope.

local storage = require("mentor.storage")

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
    { rec.identity, rec.root, rec.is_git, rec.git_common_dir, math.floor(vim.uv.now()) }
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
    "INSERT INTO chat_message (project_id, mode, role, content, tool_calls, tool_call_id, source, created_at)"
      .. " VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
    {
      project_id,
      mode,
      msg.role,
      msg.content or "",
      tool_calls,
      msg.tool_call_id,
      msg.source,
      math.floor(vim.uv.now()),
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
  local sql = "SELECT id, role, content, tool_calls, tool_call_id, source, created_at"
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
    { project_id, day, kind, model_requests, est_tokens, math.floor(vim.uv.now()) }
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
  local now = math.floor(vim.uv.now())
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

return M
