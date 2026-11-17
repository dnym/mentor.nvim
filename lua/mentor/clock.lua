-- Wall-clock time for persisted timestamps.
--
-- `vim.uv.now()` is a monotonic loop clock (milliseconds since an arbitrary
-- point, in practice boot): right for measuring durations inside one
-- process, wrong for anything stored. Stored values would read as dates in
-- 1970, and comparisons against them would break across reboots (a snooze
-- or cooldown from an earlier boot could look like it lies in the future).
-- Everything written to the database, and everything compared with stored
-- values, uses this clock instead.

local M = {}

-- Values below this (2000-01-01 in epoch ms) predate wall-clock storage:
-- they were monotonic readings and carry no calendar meaning.
M.EPOCH_FLOOR_MS = 946684800000

---@return integer milliseconds since the Unix epoch
function M.now_ms()
  local sec, usec = vim.uv.gettimeofday()
  return sec * 1000 + math.floor(usec / 1000)
end

---Calendar rendering of a stored timestamp; older monotonic readings have
---no date to show.
---@param ts integer|nil epoch milliseconds
---@param fmt string os.date format
---@return string
function M.format(ts, fmt)
  if not ts or ts < M.EPOCH_FLOOR_MS then
    return "date unknown"
  end
  return os.date(fmt, math.floor(ts / 1000))
end

return M
