-- Per-target single-flight FIFO scheduler. One operation at a time may run
-- against a given key (a provider endpoint that serves only one concurrent
-- request, for example); additional submissions queue in order and can be
-- cancelled while queued or while running.

local M = {}

local queues = {} -- key -> { busy = boolean, waiting = entry[] }

local function queue_for(key)
  local q = queues[key]
  if not q then
    q = { busy = false, waiting = {} }
    queues[key] = q
  end
  return q
end

---@param entry table queued item
local function settle(key, entry)
  if entry.settled then
    return
  end
  entry.settled = true
  if entry.on_settled then
    entry.on_settled()
  end
  if queues[key] then
    queues[key].busy = false
    M._pump(key)
  end
end

---Start the next queued item for a key; started items run to completion.
---@private
function M._pump(key)
  local q = queues[key]
  if not q or q.busy then
    return
  end
  while #q.waiting > 0 do
    local entry = table.remove(q.waiting, 1)
    if entry.cancelled then
      settle(key, entry)
    else
      q.busy = true
      entry.started = true
      local finish = function()
        settle(key, entry)
      end
      -- The task starts the real work and returns a cancellable handle (or
      -- nil + error when it could not start at all; then finish settles it).
      local ok, handle_or_err, why = pcall(entry.task, finish)
      if not ok then
        entry.handle = nil
        entry.task_error = tostring(handle_or_err)
        finish()
      elseif handle_or_err == nil then
        entry.handle = nil
        entry.task_error = why
        finish()
      else
        entry.handle = handle_or_err
      end
      return
    end
  end
end

---@class mentor.ScheduledHandle
---@field cancel fun()
---@field is_active fun(): boolean
---@field queued fun(): boolean

---Submit an operation. `task(on_finish)` starts the work; it must call
---`on_finish()` exactly once when the work settles, and return a handle with
---:cancel() and :is_active(), or nil + an actionable error.
---@param item table {key: string, task: fun(on_finish: fun()): table?, on_settled: fun()|nil}
---@return mentor.ScheduledHandle
function M.submit(item)
  local q = queue_for(item.key)
  local entry = { task = item.task, on_settled = item.on_settled, started = false, cancelled = false }
  q.waiting[#q.waiting + 1] = entry

  local proxy = {}
  function proxy:cancel()
    if entry.cancelled or entry.settled then
      return
    end
    if entry.started then
      if entry.handle and entry.handle.cancel then
        entry.handle:cancel()
      end
    else
      entry.cancelled = true
    end
  end
  function proxy:is_active()
    return entry.started and not entry.settled and entry.handle ~= nil and entry.handle:is_active()
  end
  function proxy:queued()
    return not entry.started and not entry.cancelled and not entry.settled
  end

  M._pump(item.key)
  return proxy
end

---Number of operations waiting (not running) for a key.
function M.pending_count(key)
  local q = queues[key]
  if not q then
    return 0
  end
  local n = 0
  for _, entry in ipairs(q.waiting) do
    if not entry.cancelled then
      n = n + 1
    end
  end
  return n
end

function M.reset()
  queues = {}
end

return M
