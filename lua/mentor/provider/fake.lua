-- Fake asynchronous provider: drives the UI without network access.
-- Responses stream word-by-word through the event loop so streaming and
-- cancellation paths are exercised deterministically. Tests script exact
-- responses via M.script(); interactive use falls back to a canned reply.

local M = {}

M.chunk_delay_ms = 10

---Queue exact responses (consumed in order). Each entry is a string.
---@param responses string[]
function M.script(responses)
  M._scripted = responses
end

local DEFAULT_REPLY = table.concat({
  "Mentor is running with the offline fake provider (dev.fake_provider = true).",
  "Milestone 3 connects the OpenAI-compatible provider loop;",
  "this placeholder exercises streaming, cancellation, and the chat UI.",
}, " ")

---Starts a fake streaming response.
---@param req table {text, on_delta(chunk), on_done(info)}
---@return table handle with :cancel() and :is_active()
function M.request(req)
  local text = (M._scripted and #M._scripted > 0 and table.remove(M._scripted, 1)) or DEFAULT_REPLY
  local handle = { cancelled = false, active = true }
  local chunks = {}
  for word in text:gmatch("%S+") do
    chunks[#chunks + 1] = word
  end

  local function emit(i)
    if handle.cancelled then
      return
    end
    if i > #chunks then
      handle.active = false
      if req.on_done then
        req.on_done({ ok = true, estimated_tokens = math.ceil(#text / 4) })
      end
      return
    end
    req.on_delta((i == 1 and "" or " ") .. chunks[i])
    vim.defer_fn(function()
      emit(i + 1)
    end, M.chunk_delay_ms)
  end
  vim.defer_fn(function()
    emit(1)
  end, M.chunk_delay_ms)

  function handle:cancel()
    handle.cancelled = true
    handle.active = false
    if req.on_done then
      req.on_done({ cancelled = true })
    end
  end

  function handle:is_active()
    return handle.active
  end
  return handle
end

return M
