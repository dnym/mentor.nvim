-- Bounded agent loop shared by interactive modes.
--
-- Budgets come from configuration and are enforced before every dispatch:
-- model requests, tool calls, wall-clock deadline, and estimated tokens,
-- plus per-result and aggregate tool-output caps with explicit truncation.
-- Each model request first reserves usage atomically in SQLite; the
-- reservation becomes conservatively retained once the request starts
-- reaching the provider and is only released while it is known that nothing
-- was dispatched. Stored tool results are re-authorized against the current
-- access policy before every dispatch, so a policy change that excludes a
-- source mid-operation stops transmitting that result; memory tool results
-- recheck each embedded entry's provenance the same way.
--
-- Error handling: one automatic retry per operation for transient failures
-- (transport, timeout, provider 5xx/429-class errors); deterministic
-- failures (rejected request, malformed response) end the operation with an
-- actionable message. Cancellation stops the loop and the active request.

local config = require("mentor.config")
local tools_mod = require("mentor.tools")
local policy_mod = require("mentor.policy")
local records = require("mentor.storage.records")
local memory_mod = require("mentor.memory")
local provenance = require("mentor.provenance")

local M = {}

-- Injectable provider ({ chat = ... }); defaults by configuration.
M.provider = nil

-- Crash cleanup for usage reservations, once per Neovim instance.
local swept = false
local SWEEP_STALE_MS = 30 * 60 * 1000

local function select_provider()
  if M.provider then
    return M.provider
  end
  if config.get().dev.fake_provider then
    return require("mentor.provider.fake")
  end
  return require("mentor.provider.openai")
end

local TRANSIENT_ERRORS = { transport_error = true, timeout = true, http_error = true }

---Coarse token estimate over serialized message content (chars / 4).
---@param messages table[]
---@return integer
local function estimate(messages)
  local bytes = 0
  for _, m in ipairs(messages) do
    bytes = bytes + #(m.content or "")
    if m.tool_calls then
      bytes = bytes + #vim.json.encode(m.tool_calls)
    end
  end
  return math.ceil(bytes / 4) + 64 -- per-message framing allowance
end

---Truncate a serialized tool result with an explicit marker.
local function truncate_result(text, cap)
  local cut = text
  if cap > 0 then
    cut = cut:sub(1, cap)
    -- Drop a trailing partial UTF-8 sequence so the marker stays readable.
    while #cut > 0 do
      local b = cut:byte(-1)
      if b < 0x80 then
        break
      end
      if b >= 0xC0 then
        cut = cut:sub(1, -2)
        break
      end
      cut = cut:sub(1, -2)
    end
  end
  return cut .. "\n[result truncated: exceeded the tool output byte cap]"
end

---@class mentor.AgentOptions
---@field mode "observer"|"coach"|"implement"
---@field kind "interactive"|"background"|nil defaults to interactive
---@field project mentor.Project
---@field messages table[] initial conversation (system prompt first)
---@field tools string[]|nil allowed tool names (default: all)
---@field on_delta fun(chunk: string)|nil streamed answer text
---@field on_tool fun(phase: "start"|"done", call: table, result: table|nil)|nil
---@field on_message fun(msg: table)|nil each assistant/tool message appended
---@field on_note fun(text: string)|nil progress notices (retries)
---@field tool_ctx_extra table|nil extra fields merged into the tool operation
---  context (used by the Observer engine to attach its findings sink)
---@field on_done fun(err: string|nil, info: table) terminal callback, exactly once

---Run one bounded agent operation. Returns a handle with :cancel() and :is_active().
---@param opts mentor.AgentOptions
---@return table|nil handle, string|nil actionable error
function M.run(opts)
  if type(opts.messages) ~= "table" or opts.messages[1] == nil then
    return nil, "mentor.nvim: agent requires a non-empty message list"
  end
  if not swept then
    swept = true
    pcall(function()
      records.usage.sweep(SWEEP_STALE_MS)
    end)
  end
  local kind = opts.kind or "interactive"
  local cfg = config.get()
  local limits = kind == "background" and cfg.limits.background or cfg.limits.interactive
  local settings = require("mentor.provider").settings(opts.mode)
  local provider = select_provider()
  local project_id = records.projects.touch({
    identity = opts.project.identity,
    root = opts.project.root,
    is_git = opts.project.is_git,
    git_common_dir = opts.project.git_common_dir,
  })

  -- Working copy: internal messages carry provenance (source) and the
  -- producing tool name that must not be serialized to the provider;
  -- content may be withheld per message.
  local messages = {}
  for i, m in ipairs(opts.messages) do
    messages[i] = {
      role = m.role,
      content = m.content,
      tool_calls = m.tool_calls,
      tool_call_id = m.tool_call_id,
      source = m.source,
      tool = m.tool,
    }
  end

  local tool_ctx = tools_mod.new_operation({ project = opts.project })
  for key, value in pairs(opts.tool_ctx_extra or {}) do
    tool_ctx[key] = value
  end
  local tool_schemas = tools_mod.schemas(opts.tools)
  local deadline = vim.uv.now() + limits.elapsed_s * 1000
  local day = records.usage.today()

  local op = { cancelled = false, active = true, provider_handle = nil, tool_ctx = tool_ctx }
  local finished = false
  local model_requests_used = 0
  local tool_calls_used = 0
  local est_spent = 0
  local reported_input = 0
  local reported_output = 0
  local tool_bytes_total = 0
  local retries_left = cfg.limits.retries_per_operation
  local last_content = nil

  local function usage_summary()
    return {
      model_requests = model_requests_used,
      tool_calls = tool_calls_used,
      estimated_tokens = est_spent,
      reported_input = reported_input,
      reported_output = reported_output,
    }
  end

  local function finish(err, info)
    if finished then
      return
    end
    finished = true
    op.active = false
    op.provider_handle = nil
    if opts.on_done then
      opts.on_done(err, info or {})
    end
  end

  local function stop_at_limit(reason)
    return finish(nil, {
      content = last_content,
      stop_reason = reason,
      usage = usage_summary(),
    })
  end

  ---Recheck every stored tool result against the current access policy.
  local function recheck_stored_context()
    local pol = policy_mod.for_project(opts.project)
    for _, m in ipairs(messages) do
      if m.role == "tool" and not m.withheld then
        if m.tool and m.tool:find("^memory_") then
          local rewritten, changed = memory_mod.reauthorize_result(m.content, opts.project)
          if changed then
            m.content = rewritten
          end
        elseif tools_mod.group_of(m.tool) == "investigation" or not m.tool then
          if not provenance.authorized(m.source, m.tool, pol) then
            m.content = provenance.withheld
            m.withheld = true
          end
        end
      end
    end
  end

  ---Provider-format messages (provenance stripped).
  local function provider_messages()
    local out = {}
    for _, m in ipairs(messages) do
      local pm = { role = m.role }
      pm.content = m.content or ""
      if m.tool_calls then
        pm.tool_calls = m.tool_calls
      end
      if m.tool_call_id then
        pm.tool_call_id = m.tool_call_id
      end
      out[#out + 1] = pm
    end
    return out
  end

  local dispatch -- forward declaration

  local function after_reservation_settled(reservation, dispatched, next_est)
    if dispatched then
      -- The request may have reached the provider: retain conservative usage.
      records.usage.commit_actual(reservation, next_est)
    else
      records.usage.release(reservation)
    end
  end

  local function handle_result(reservation, next_est, dispatched_flag, err, info)
    if err == "cancelled" then
      after_reservation_settled(reservation, dispatched_flag.flag, next_est)
      return finish("cancelled", { usage = usage_summary() })
    end
    if err then
      after_reservation_settled(reservation, dispatched_flag.flag, next_est)
      if TRANSIENT_ERRORS[err] and retries_left > 0 and not op.cancelled and vim.uv.now() < deadline then
        retries_left = retries_left - 1
        if opts.on_note then
          opts.on_note("provider hiccup (" .. ((info and info.message) or err) .. "); retrying once")
        end
        return dispatch()
      end
      return finish(err, {
        message = (info and info.message) or ("provider request failed: " .. err),
        usage = usage_summary(),
      })
    end

    local input = info.usage and tonumber(info.usage.input) or nil
    local output = info.usage and tonumber(info.usage.output) or nil
    local actual_est = (input ~= nil and output ~= nil) and (input + output) or next_est
    records.usage.commit_actual(reservation, actual_est, input, output)
    est_spent = est_spent + actual_est
    reported_input = reported_input + (input or 0)
    reported_output = reported_output + (output or 0)
    model_requests_used = model_requests_used + 1

    local assistant = { role = "assistant", content = info.content or "" }
    if info.tool_calls and #info.tool_calls > 0 then
      assistant.tool_calls = {}
      for i, call in ipairs(info.tool_calls) do
        assistant.tool_calls[i] = {
          id = call.id,
          type = "function",
          ["function"] = { name = call.name, arguments = call.raw },
        }
      end
    end
    messages[#messages + 1] = assistant
    last_content = assistant.content
    if opts.on_message then
      local persistable = { role = "assistant", content = assistant.content }
      if info.tool_calls and #info.tool_calls > 0 then
        persistable.tool_calls = {}
        for _, call in ipairs(info.tool_calls) do
          persistable.tool_calls[#persistable.tool_calls + 1] = {
            id = call.id,
            name = call.name,
            arguments = call.arguments,
          }
        end
      end
      opts.on_message(persistable)
    end

    if info.tool_calls and #info.tool_calls > 0 then
      for _, call in ipairs(info.tool_calls) do
        if op.cancelled then
          return finish("cancelled", { usage = usage_summary() })
        end
        if tool_calls_used >= limits.tool_calls then
          return stop_at_limit("tool call limit (" .. limits.tool_calls .. ") reached; ask again to continue")
        end
        if vim.uv.now() >= deadline then
          return stop_at_limit("elapsed time limit (" .. limits.elapsed_s .. "s) reached")
        end
        tool_calls_used = tool_calls_used + 1
        if opts.on_tool then
          opts.on_tool("start", call, nil)
        end
        tool_ctx.provenance = {}
        local result = tools_mod.run(tool_ctx, call.name, call.arguments)
        local serialized = vim.json.encode(result)
        if #serialized > limits.tool_result_bytes then
          serialized = truncate_result(serialized, limits.tool_result_bytes)
        end
        local remaining = limits.tool_total_bytes - tool_bytes_total
        if #serialized > remaining then
          serialized = truncate_result(serialized, math.max(0, remaining))
        end
        tool_bytes_total = tool_bytes_total + #serialized
        local source
        if tools_mod.group_of(call.name) == "investigation" then
          source = provenance.capture(tool_ctx, call.arguments or {}, result)
        end
        messages[#messages + 1] = {
          role = "tool",
          tool_call_id = call.id,
          content = serialized,
          source = source,
          tool = call.name,
        }
        if opts.on_message then
          opts.on_message({
            role = "tool",
            content = serialized,
            tool_call_id = call.id,
            source = source,
            tool = call.name,
          })
        end
        if opts.on_tool then
          opts.on_tool("done", call, result)
        end
      end
      return dispatch()
    end

    return finish(nil, {
      content = info.content,
      stop_reason = info.finish_reason or "stop",
      usage = usage_summary(),
    })
  end

  dispatch = function()
    if op.cancelled or finished then
      return
    end
    if model_requests_used >= limits.model_requests then
      return stop_at_limit(
        "model request limit (" .. limits.model_requests .. ") reached; ask again to continue"
      )
    end
    if vim.uv.now() >= deadline then
      return stop_at_limit("elapsed time limit (" .. limits.elapsed_s .. "s) reached")
    end
    if kind == "background" then
      -- Cross-instance gates for automatic work: background load for this
      -- project (committed totals + in-flight reservations) is capped per
      -- hour and per day so multiple Neovim instances cannot stack up.
      local hourly_cap = limits.requests_per_hour_per_project
      local daily_cap = limits.est_tokens_per_day_per_project
      if (hourly_cap and hourly_cap > 0) or (daily_cap and daily_cap > 0) then
        local window = records.usage.window(project_id, day, 3600000)
        if hourly_cap and hourly_cap > 0 and window.requests_hour >= hourly_cap then
          return stop_at_limit(
            "background hourly request cap (" .. hourly_cap .. ") reached for this project"
          )
        end
        if daily_cap and daily_cap > 0 and window.est_tokens_day >= daily_cap then
          return stop_at_limit(
            "background daily estimated token cap (" .. daily_cap .. ") reached for this project"
          )
        end
      end
    end
    recheck_stored_context()
    local next_est = estimate(messages)
    if est_spent + next_est > limits.est_tokens then
      return stop_at_limit(
        "estimated token budget (" .. limits.est_tokens .. " tokens) reached; ask a narrower question"
      )
    end

    local reservation = records.usage.reserve(project_id, day, kind, 1, next_est)
    local dispatched_flag = { flag = false }
    local handle, perr = provider.chat({
      settings = settings,
      messages = provider_messages(),
      tools = #tool_schemas > 0 and tool_schemas or nil,
      on_delta = opts.on_delta,
      on_start = function()
        dispatched_flag.flag = true
        records.usage.mark_dispatched(reservation)
      end,
      on_done = function(err, info)
        handle_result(reservation, next_est, dispatched_flag, err, info)
      end,
    })
    if not handle then
      records.usage.release(reservation)
      return finish("transport_error", { message = perr, usage = usage_summary() })
    end
    op.provider_handle = handle
  end

  function op:cancel()
    if op.cancelled then
      return
    end
    op.cancelled = true
    if op.provider_handle then
      op.provider_handle:cancel() -- terminal on_done arrives from the provider
    else
      finish("cancelled", { usage = usage_summary() })
    end
  end

  function op:is_active()
    return op.active and not finished
  end

  dispatch()
  return op
end

return M
