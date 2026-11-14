-- OpenAI-compatible Chat Completions adapter.
--
-- Request: model, messages, optional native tools, and per-request token
-- cap; credentials (when an api_key_env names one) travel only in a header
-- passed through the transport's protected stdin, never in process arguments.
--
-- Response: SSE streams are parsed incrementally across arbitrary chunk
-- boundaries; assistant content deltas are forwarded as they arrive, and
-- streamed tool-call fragments are accumulated by index and validated only
-- once complete — an incomplete call never reaches execution. Responses are
-- capped so a broken server cannot exhaust memory. Requests are serialized
-- per endpoint through the scheduler: providers commonly serve one
-- concurrent request, and queued requests proceed automatically.

local transport = require("mentor.provider.transport")
local sse = require("mentor.provider.sse")
local scheduler = require("mentor.scheduler")

local M = {}

-- Test override for the transport module.
---@private
M._transport = transport

-- Hard cap on what one response may produce: answer text, reasoning, and
-- tool-call names/arguments (decoded). In streaming mode the SSE framing
-- around each token (ids, timestamps, JSON keys; often 10-50x the token
-- itself) does not count against it; for a non-streaming response the
-- body is the payload, so the raw body is capped instead.
M.max_response_bytes = 524288

-- Separate guard on raw stream bytes, so a server that streams endless
-- framing, keep-alives, or empty deltas still cannot run unbounded.
M.max_stream_bytes = 33554432

-- Streaming keeps at most this much raw text, for provider error bodies
-- (which arrive on stdout with an HTTP error) and diagnostics.
M.max_error_body_bytes = 65536

---Actionable message from an error body shaped like {"error":{"message":...}}.
local function provider_error_message(body)
  local ok, decoded = pcall(vim.json.decode, body or "")
  if ok and type(decoded) == "table" then
    local err = decoded.error
    if type(err) == "table" and type(err.message) == "string" and err.message ~= "" then
      return err.message, err.type
    end
    if type(err) == "string" and err ~= "" then
      return err
    end
  end
  local trimmed = vim.trim(body or "")
  if trimmed ~= "" then
    return trimmed:sub(1, 400)
  end
  return "the provider returned an error response"
end

-- HTTP statuses worth one automatic retry: timeouts, conflicts, rate
-- limits, and server-side failures. Every other 4xx is deterministic.
local TRANSIENT_STATUS = { [408] = true, [409] = true, [425] = true, [429] = true }

---Whether an HTTP error response may succeed on retry. Uses the status
---when curl reported one; otherwise falls back to the error body's type.
---@param status integer|nil
---@param error_type string|nil
---@return boolean
function M._http_error_is_transient(status, error_type)
  if status then
    return status >= 500 or TRANSIENT_STATUS[status] == true
  end
  return error_type ~= "invalid_request_error"
end

local function status_label(status)
  return status and (" (HTTP " .. status .. ")") or ""
end

local function rejection_hint(status)
  if status == 401 or status == 403 then
    return " — check the API key (provider.api_key_env names the environment variable)"
  elseif status == 404 then
    return " — check provider.endpoint (an OpenAI-compatible base URL such as http://host:port/v1)"
  end
  return ""
end

---An actionable message for curl-level transport failures. The exit code is
---curl's; the common ones name the likely cause and where to look.
---@param kind string "timeout" | "transport_error" | other class
---@param exit_code integer|string|nil curl exit code
---@param settings table provider settings
---@return string
local function transport_failure_message(kind, exit_code, settings)
  if kind == "timeout" then
    return string.format(
      "the provider request timed out after %d s (raise provider.timeout_s, or check the endpoint)",
      math.floor(settings.timeout_s or 0)
    )
  end
  if exit_code == 6 then
    return "the endpoint host could not be resolved (check provider.endpoint: " .. settings.endpoint .. ")"
  end
  if exit_code == 7 then
    return "the endpoint refused the connection (is the provider server running? check provider.endpoint: "
      .. settings.endpoint
      .. ")"
  end
  if exit_code == 28 then
    return "the endpoint transfer exceeded its time limit"
  end
  return string.format("transport failure (curl exit %s); run :checkhealth mentor", tostring(exit_code))
end

---@class mentor.ToolCall
---@field id string
---@field name string
---@field arguments table decoded tool arguments
---@field raw string original arguments string

---@class mentor.ProviderResult
---@field content string assistant text (without reasoning)
---@field tool_calls mentor.ToolCall[]|nil complete native tool calls
---@field finish_reason string|nil stop|length|tool_calls|...
---@field usage {input: integer, output: integer}|nil provider-reported tokens

---Build the chat-completions request body.
---@param req table {settings, messages, tools}
---@return string body, boolean streaming
local function build_body(req)
  local settings = req.settings
  local streaming = settings.capabilities.streaming and true or false
  local body = {
    model = settings.model,
    messages = req.messages,
    max_tokens = settings.max_tokens,
    stream = streaming,
  }
  if streaming then
    body.stream_options = { include_usage = true }
  end
  if req.tools and settings.capabilities.tools then
    body.tools = req.tools
  end
  return vim.json.encode(body), streaming
end

local function auth_headers(settings, streaming)
  local headers = {
    "Content-Type: application/json",
    "Accept: " .. (streaming and "text/event-stream" or "application/json"),
  }
  local key = settings.api_key_env ~= "" and vim.env[settings.api_key_env] or nil
  if key ~= nil and key ~= "" then
    headers[#headers + 1] = "Authorization: Bearer " .. key
  end
  return headers
end

---Accumulates one streamed response: content, reasoning length, and
---tool-call fragments keyed by position.
local function new_state()
  return {
    content_parts = {},
    content_bytes = 0,
    payload_bytes = 0, -- content + reasoning + tool-call fragments, decoded
    tool_calls = {}, -- index -> {id, name, argument_parts}
    finish_reason = nil,
    usage = nil,
    saw_done = false,
    saw_data = false,
    problems = {},
  }
end

---Fold one decoded chunk object into the accumulation state.
local function absorb_chunk(state, chunk, on_delta)
  if type(chunk.usage) == "table" then
    state.usage = {
      input = tonumber(chunk.usage.prompt_tokens) or 0,
      output = tonumber(chunk.usage.completion_tokens) or 0,
    }
  end
  if type(chunk.choices) ~= "table" then
    return
  end
  for _, choice in ipairs(chunk.choices) do
    if type(choice.finish_reason) == "string" and choice.finish_reason ~= "" then
      state.finish_reason = choice.finish_reason
    end
    local delta = choice.delta
    if type(delta) == "table" then
      if type(delta.content) == "string" and delta.content ~= "" then
        state.content_parts[#state.content_parts + 1] = delta.content
        state.content_bytes = state.content_bytes + #delta.content
        state.payload_bytes = state.payload_bytes + #delta.content
        if on_delta then
          on_delta(delta.content)
        end
      end
      -- reasoning_content deltas exist on some models; the UI shows only
      -- answer content, so they are counted here and otherwise dropped.
      if type(delta.reasoning_content) == "string" then
        state.payload_bytes = state.payload_bytes + #delta.reasoning_content
      end
      if type(delta.tool_calls) == "table" then
        for _, frag in ipairs(delta.tool_calls) do
          local idx = (tonumber(frag.index) or 0) + 1
          local acc = state.tool_calls[idx]
          if not acc then
            acc = { id = nil, name = nil, argument_parts = {} }
            state.tool_calls[idx] = acc
          end
          if type(frag.id) == "string" and frag.id ~= "" then
            acc.id = frag.id
          end
          if type(frag["function"]) == "table" then
            if type(frag["function"].name) == "string" and frag["function"].name ~= "" then
              acc.name = frag["function"].name
              state.payload_bytes = state.payload_bytes + #acc.name
            end
            if type(frag["function"].arguments) == "string" then
              acc.argument_parts[#acc.argument_parts + 1] = frag["function"].arguments
              state.payload_bytes = state.payload_bytes + #frag["function"].arguments
            end
          end
        end
      end
    end
  end
end

---Validate and normalize accumulated tool calls. Returns nil + an actionable
---message when the stream produced an incomplete or undecodable call: those
---must never be executed.
---@return mentor.ToolCall[]|nil calls, string|nil problem
local function finalize_tool_calls(state)
  local present = false
  for _ in pairs(state.tool_calls) do
    present = true
    break
  end
  if not present then
    return {}
  end
  local calls = {}
  for idx = 1, #state.tool_calls do
    local acc = state.tool_calls[idx]
    if not acc then
      return nil, string.format("tool call at position %d is missing (stream interrupted)", idx)
    end
    if acc.name == nil or acc.name == "" then
      return nil, "streamed tool call is missing its name (incomplete response)"
    end
    local raw = table.concat(acc.argument_parts)
    local ok, decoded = pcall(vim.json.decode, raw == "" and "{}" or raw)
    if not ok or type(decoded) ~= "table" then
      return nil,
        string.format("tool call %s has incomplete or invalid arguments (stream truncated)", acc.name)
    end
    calls[#calls + 1] = {
      id = acc.id or ("mentor_call_" .. idx),
      name = acc.name,
      arguments = decoded,
      raw = raw,
    }
  end
  return calls
end

---Normalize a non-streaming chat-completions response body.
local function parse_non_streaming(body)
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" or type(decoded.choices) ~= "table" or decoded.choices[1] == nil then
    return nil, "the provider response was not a readable chat completion"
  end
  local choice = decoded.choices[1]
  local message = type(choice.message) == "table" and choice.message or {}
  local calls = {}
  if type(message.tool_calls) == "table" then
    for i, call in ipairs(message.tool_calls) do
      local fn = type(call["function"]) == "table" and call["function"] or {}
      if type(fn.name) ~= "string" or fn.name == "" then
        return nil, "tool call at position " .. i .. " is missing its name"
      end
      local raw = type(fn.arguments) == "string" and fn.arguments or "{}"
      local ok_args, decoded_args = pcall(vim.json.decode, raw == "" and "{}" or raw)
      if not ok_args or type(decoded_args) ~= "table" then
        return nil, "tool call " .. fn.name .. " carried invalid arguments"
      end
      calls[#calls + 1] = {
        id = (type(call.id) == "string" and call.id ~= "") and call.id or ("mentor_call_" .. i),
        name = fn.name,
        arguments = decoded_args,
        raw = raw,
      }
    end
  end
  local usage = nil
  if type(decoded.usage) == "table" then
    usage = {
      input = tonumber(decoded.usage.prompt_tokens) or 0,
      output = tonumber(decoded.usage.completion_tokens) or 0,
    }
  end
  return {
    content = type(message.content) == "string" and message.content or "",
    tool_calls = calls,
    finish_reason = type(choice.finish_reason) == "string" and choice.finish_reason or nil,
    usage = usage,
  }
end

---@class mentor.ProviderChatRequest
---@field settings table merged provider settings
---@field messages table[] OpenAI-format messages
---@field tools table[]|nil OpenAI tool schemas
---@field on_delta fun(chunk: string)|nil streamed answer content
---@field on_done fun(err: string|nil, info: mentor.ProviderResult|{message: string}|nil)

---Start one chat completion. Errors arrive as a code plus actionable message:
---cancelled, timeout, transport_error, http_error (transient),
---request_rejected (provider rejected the request itself), malformed_response,
---response_too_large, no_response.
---@param req mentor.ProviderChatRequest
---@return mentor.ScheduledHandle|nil handle, string|nil actionable error
function M.chat(req)
  local settings = req.settings
  if settings.endpoint == "" or settings.model == "" then
    return nil, "mentor.nvim: provider endpoint and model must be configured before a request"
  end
  local err = M._transport.check()
  if err then
    return nil, err
  end

  local url = (settings.endpoint:gsub("/+$", "")) .. "/chat/completions"
  local body, streaming = build_body(req)
  local state = new_state()
  local parser = streaming
      and sse.new(function(payload)
        state.saw_data = true
        if payload == "[DONE]" then
          state.saw_done = true
          return
        end
        local ok, chunk = pcall(vim.json.decode, payload)
        if not ok or type(chunk) ~= "table" then
          state.problems[#state.problems + 1] = "malformed stream chunk"
          return
        end
        absorb_chunk(state, chunk, req.on_delta)
      end)
    or nil

  local raw = {}
  local raw_bytes = 0 -- every byte received
  local kept_bytes = 0 -- bytes retained in `raw`
  local overflow = nil -- message once a cap is exceeded
  local delivered = false

  local function deliver(err, info)
    if delivered then
      return
    end
    delivered = true
    req.on_done(err, info)
  end

  local function feed(chunk)
    if overflow then
      return
    end
    raw_bytes = raw_bytes + #chunk
    if not parser then
      -- Non-streaming: the body is the payload and must be kept whole.
      if raw_bytes > M.max_response_bytes then
        overflow = string.format(
          "provider response exceeded the %d KiB accumulation cap",
          math.floor(M.max_response_bytes / 1024)
        )
        return
      end
      raw[#raw + 1] = chunk
      return
    end
    if raw_bytes > M.max_stream_bytes then
      overflow = string.format(
        "provider stream exceeded the %d KiB raw stream cap",
        math.floor(M.max_stream_bytes / 1024)
      )
      return
    end
    if kept_bytes < M.max_error_body_bytes then
      local piece = chunk:sub(1, M.max_error_body_bytes - kept_bytes)
      raw[#raw + 1] = piece
      kept_bytes = kept_bytes + #piece
    end
    parser:feed(chunk)
    if state.payload_bytes > M.max_response_bytes then
      overflow = string.format(
        "provider response exceeded the %d KiB accumulation cap",
        math.floor(M.max_response_bytes / 1024)
      )
    end
  end

  -- Serialize per endpoint: a single-request provider never sees two of our
  -- requests at once; extras queue automatically in order. The transport
  -- process only starts when the queue slot comes up.
  local proxy = scheduler.submit({
    key = settings.endpoint,
    on_settled = function()
      -- A queued request cancelled before it started settles without a
      -- transport; streaming callers still expect one terminal callback.
      deliver("cancelled")
    end,
    task = function(on_finish)
      if delivered then
        return nil, "cancelled before dispatch"
      end
      -- Marks the boundary after which the request may exist at the provider:
      -- usage accounting switches from releasable to conservatively retained.
      if req.on_start then
        req.on_start()
      end
      local handle, terr = M._transport.request({
        url = url,
        headers = auth_headers(settings, streaming),
        body = body,
        timeout_s = settings.timeout_s,
        on_delta = feed,
        on_exit = function(kind, exit_code, http_status)
          if overflow then
            deliver("response_too_large", { message = overflow })
            on_finish()
            return
          end
          local collected = table.concat(raw)
          if kind == "cancelled" then
            deliver("cancelled")
          elseif kind == "http_error" then
            -- --fail-with-body delivers the provider's error body on stdout.
            local message, pkind = provider_error_message(collected)
            if M._http_error_is_transient(http_status, pkind) then
              deliver(
                "http_error",
                { message = "provider error" .. status_label(http_status) .. ": " .. message }
              )
            else
              deliver("request_rejected", {
                message = "provider rejected the request"
                  .. status_label(http_status)
                  .. ": "
                  .. message
                  .. rejection_hint(http_status),
              })
            end
          elseif kind ~= nil then
            deliver(kind, { message = transport_failure_message(kind, exit_code, settings) })
          elseif streaming then
            if #state.problems > 0 then
              deliver("malformed_response", {
                message = "provider stream contained invalid data (" .. state.problems[1] .. ")",
              })
            elseif not state.saw_done and parser:has_pending_event() then
              deliver("malformed_response", { message = "provider stream ended mid-event" })
            elseif not state.saw_data then
              deliver("no_response", { message = "provider returned an empty stream" })
            else
              local calls, problem = finalize_tool_calls(state)
              if not calls then
                deliver("malformed_response", { message = problem })
              else
                deliver(nil, {
                  content = table.concat(state.content_parts),
                  tool_calls = #calls > 0 and calls or nil,
                  finish_reason = state.finish_reason,
                  usage = state.usage,
                })
              end
            end
          else
            local result, problem = parse_non_streaming(collected)
            if not result then
              deliver("malformed_response", { message = problem })
            else
              deliver(nil, result)
            end
          end
          on_finish()
        end,
      })
      if not handle then
        deliver("transport_error", { message = terr })
        on_finish()
        return nil, terr
      end
      return handle
    end,
  })
  return proxy
end

return M
