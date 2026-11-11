-- Unit: the SSE line accumulator must survive arbitrary transport chunk
-- boundaries: splits mid-line, mid-event, several events per chunk, CRLF
-- endings, keep-alive comments, and multi-line data fields.

local H = require("tests.support.harness")
local sse = require("mentor.provider.sse")

return function()
  ---Collects dispatched event payloads.
  local function collector()
    local events = {}
    local parser = sse.new(function(payload)
      events[#events + 1] = payload
    end)
    return parser, events
  end

  H.test("complete events split across arbitrary chunks dispatch exactly once", function()
    local parser, events = collector()
    local stream = table.concat({
      'data: {"a":1}\n',
      "\n",
      "data: first\n",
      "data: second\n",
      "\n",
    })
    -- Feed one character at a time: the worst-case boundary behaviour.
    for i = 1, #stream do
      parser:feed(stream:sub(i, i))
    end
    H.eq(#events, 2, "two events")
    H.eq(events[1], '{"a":1}', "payload one")
    H.eq(events[2], "first\nsecond", "multi-line data joins with newline")
  end)

  H.test("CRLF endings and keep-alive comments are handled", function()
    local parser, events = collector()
    parser:feed(": keep-alive\r\n\r\n")
    parser:feed('data: {"b":2}\r\n\r\n')
    parser:feed(": keep-alive\r\n")
    parser:feed("data: do")
    parser:feed("ne\r\n\r\n")
    H.eq(#events, 2, "comments produce no events")
    H.eq(events[1], '{"b":2}', "crlf payload")
    H.eq(events[2], "done", "split payload")
  end)

  H.test("a stream ending mid-event leaves a detectable truncation", function()
    local parser, events = collector()
    parser:feed("data: partial")
    H.eq(#events, 0, "no dispatch without the terminating blank line")
    H.ok(parser:has_pending_event(), "pending event is visible")
  end)

  H.test("oversized lines mark overflow instead of buffering forever", function()
    local old_cap = sse.max_line_bytes
    sse.max_line_bytes = 32
    local parser, events = collector()
    parser:feed("data: " .. string.rep("x", 100))
    H.ok(parser.overflow, "overflow flagged")
    parser:feed("\n\n")
    H.eq(#events, 0, "overflowed event never dispatches")
    sse.max_line_bytes = old_cap
  end)

  H.test("field values keep interior colons and spaces per SSE framing", function()
    local parser, events = collector()
    parser:feed('data: {"url":"http://x:8080/v1"}\n\n')
    parser:feed("data:no leading space\n\n")
    H.eq(events[1], '{"url":"http://x:8080/v1"}', "interior colon intact")
    H.eq(events[2], "no leading space", "one leading space stripped")
  end)
end
