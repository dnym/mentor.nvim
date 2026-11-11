-- Server-Sent Events line accumulator. Survives arbitrary chunk boundaries:
-- chunks may split mid-line, mid-event, or carry several events at once.
-- Comment lines (": keep-alive"), CRLF endings, and multi-line data fields
-- follow the SSE wire format.

local M = {}

-- A single line larger than this indicates a broken or hostile stream.
M.max_line_bytes = 1048576

---@class mentor.SSEParser
local Parser = {}
Parser.__index = Parser

---@param on_event fun(payload: string) called once per completed event with
---the concatenated data-field value
---@return mentor.SSEParser
function M.new(on_event)
  return setmetatable({
    on_event = on_event,
    remainder = "",
    data_parts = nil,
    overflow = false,
  }, Parser)
end

function Parser:handle_line(line)
  if line == "" then
    if self.data_parts then
      local payload = table.concat(self.data_parts, "\n")
      self.data_parts = nil
      self.on_event(payload)
    end
    return
  end
  if line:sub(1, 1) == ":" then
    return -- comment or keep-alive
  end
  local colon = line:find(":", 1, true)
  if not colon then
    return -- field name with no value: no SSE field is meaningful this way
  end
  local field = line:sub(1, colon - 1)
  local value = line:sub(colon + 1)
  if value:sub(1, 1) == " " then
    value = value:sub(2)
  end
  if field == "data" then
    self.data_parts = self.data_parts or {}
    self.data_parts[#self.data_parts + 1] = value
  end
  -- event:, id:, retry: carry no meaning for this client.
end

---Feed one transport chunk; may contain any number of partial lines.
function Parser:feed(chunk)
  if self.overflow or chunk == nil or chunk == "" then
    return
  end
  self.remainder = self.remainder .. chunk
  while true do
    local nl = self.remainder:find("\n", 1, true)
    if not nl then
      break
    end
    local line = self.remainder:sub(1, nl - 1)
    self.remainder = self.remainder:sub(nl + 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    if #line > M.max_line_bytes then
      self.overflow = true
      self.remainder = ""
      return
    end
    self:handle_line(line)
  end
  if #self.remainder > M.max_line_bytes then
    self.overflow = true
    self.remainder = ""
  end
end

---A stream that ends without a trailing blank line leaves its final event
---undispatched (the wire format requires it); report it as truncation. A
---half-line still in the remainder counts as mid-event too.
---@return boolean pending_event_leftover
function Parser:has_pending_event()
  return self.data_parts ~= nil or self.remainder ~= ""
end

return M
