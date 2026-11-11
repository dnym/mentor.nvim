-- Fake asynchronous provider: drives the agent loop and UI without network
-- access. Answer text streams word-by-word through the event loop so
-- streaming and cancellation paths are exercised deterministically. Tests
-- script exact responses via M.script(): a string is plain answer content; a
-- table may carry {content, tool_calls = {{name, arguments, id?}},
-- finish_reason}. Interactive use falls back to a canned reply.

local M = {}

M.chunk_delay_ms = 10

---Queue exact responses (consumed in order).
---@param responses (string|table)[]
function M.script(responses)
  M._scripted = responses
end

local DEFAULT_REPLY = table.concat({
  "Mentor is running with the offline fake provider (dev.fake_provider = true).",
  "Configure providers.default.endpoint and model to use a real",
  "OpenAI-compatible provider.",
}, " ")

---@param req table {settings, messages, tools, on_delta, on_start, on_done(err, info)}
---@return table handle with :cancel() and :is_active()
function M.chat(req)
  local entry = M._scripted and #M._scripted > 0 and table.remove(M._scripted, 1) or DEFAULT_REPLY
  if type(entry) == "string" then
    entry = { content = entry }
  end
  local text = entry.content or ""
  local calls = {}
  for i, call in ipairs(entry.tool_calls or {}) do
    calls[i] = {
      id = call.id or ("fake_call_" .. i),
      name = call.name,
      arguments = call.arguments or {},
      raw = vim.json.encode(call.arguments or {}),
    }
  end
  if #calls > 0 and entry.finish_reason == nil then
    entry.finish_reason = "tool_calls"
  end

  local handle = { cancelled = false, active = true }
  local finished = false

  local function deliver()
    if finished or handle.cancelled then
      return
    end
    finished = true
    handle.active = false
    if req.on_done then
      local est = math.ceil(#text / 4)
      req.on_done(nil, {
        content = text,
        tool_calls = #calls > 0 and calls or nil,
        finish_reason = entry.finish_reason or (#calls > 0 and "tool_calls" or "stop"),
        usage = entry.usage or { input = est, output = est },
      })
    end
  end

  if req.on_start then
    req.on_start()
  end

  local words = {}
  for word in text:gmatch("%S+") do
    words[#words + 1] = word
  end

  local function emit(i)
    if handle.cancelled then
      return
    end
    if i > #words then
      deliver()
      return
    end
    if req.on_delta then
      req.on_delta((i == 1 and "" or " ") .. words[i])
    end
    vim.defer_fn(function()
      emit(i + 1)
    end, M.chunk_delay_ms)
  end
  vim.defer_fn(function()
    emit(1)
  end, M.chunk_delay_ms)

  function handle:cancel()
    if handle.cancelled then
      return
    end
    handle.cancelled = true
    handle.active = false
    if req.on_done then
      req.on_done("cancelled")
    end
  end

  function handle:is_active()
    return handle.active
  end
  return handle
end

return M
