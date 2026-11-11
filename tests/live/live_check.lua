-- Env-gated live verification against a real OpenAI-compatible endpoint.
-- The committed suite stays network-free; this check runs only when the
-- environment explicitly asks for it:
--
--   MENTOR_LIVE_ENDPOINT=http://host:port/v1 MENTOR_LIVE_MODEL=<model> make live-test
--
-- It drives the real curl transport and the real SSE/tool pipeline against
-- the endpoint and asserts: streamed deltas and usage accounting, a native
-- tool roundtrip, the per-endpoint single-flight queue (one concurrent
-- request at a time), and that policy-excluded file contents never appear
-- in any outbound request body.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local mentor = require("mentor")
local project = require("mentor.project")
local agent = require("mentor.agent")
local storage = require("mentor.storage")
local openai = require("mentor.provider.openai")
local real_transport = require("mentor.provider.transport")

local SECRET_MARKER = "LIVE-SECRET-MARKER-9b1d7c"

local endpoint = vim.env.MENTOR_LIVE_ENDPOINT
local model = vim.env.MENTOR_LIVE_MODEL

return function()
  if not endpoint or endpoint == "" or not model or model == "" then
    io.write("live check skipped: set MENTOR_LIVE_ENDPOINT and MENTOR_LIVE_MODEL to run it\n")
    return
  end
  if real_transport.check() then
    H.ok(false, "curl transport unavailable for live check")
    return
  end

  -- Spy transport: record every outbound body and the real concurrency
  -- level at the transport boundary (after the scheduler releases a slot).
  local bodies = {}
  local inflight, max_inflight = 0, 0
  local spy = { check = real_transport.check }
  function spy.request(req)
    bodies[#bodies + 1] = req.body or ""
    inflight = inflight + 1
    max_inflight = math.max(max_inflight, inflight)
    local original_exit = req.on_exit
    req.on_exit = function(...)
      inflight = inflight - 1
      original_exit(...)
    end
    return real_transport.request(req)
  end
  openai._transport = spy

  ---Fixture repo with an excluded credential file and a readable source file.
  local function fixture(label)
    local dir = fs.git_repo(fs.tmpdir() .. "/live-" .. label)
    fs.write(dir .. "/main.lua", "print('live fixture prints hello')\n")
    fs.write(dir .. "/.env", "API_KEY=" .. SECRET_MARKER .. "\n")
    return project.for_dir(dir)
  end

  local function configure(label)
    mentor.shutdown()
    storage.close()
    agent.provider = nil
    mentor.setup({
      dev = { fake_provider = false },
      data_dir = fs.tmpdir() .. "/data-live-" .. label,
      providers = {
        default = {
          endpoint = endpoint,
          model = model,
          api_key_env = "",
          timeout_s = 300,
          -- Reasoning-heavy models spend much of the completion budget on
          -- internal reasoning before answering; leave room.
          max_tokens = 8192,
          capabilities = { tools = true, streaming = true },
        },
      },
      limits = { interactive = { elapsed_s = 600, model_requests = 8, tool_calls = 12 } },
    })
  end

  ---Start an agent operation without waiting; fills `got.done` when settled.
  local function run_start(proj, question)
    local got = { deltas = 0, tools = {}, chars = 0 }
    local handle = agent.run({
      mode = "coach",
      project = proj,
      messages = {
        { role = "user", content = question },
      },
      on_delta = function(chunk)
        got.deltas = got.deltas + 1
        got.chars = got.chars + #chunk
      end,
      on_tool = function(phase, call, result)
        if phase == "done" then
          got.tools[#got.tools + 1] =
            { name = call.name, ok = result and result.ok, error = result and result.error }
        end
      end,
      on_done = function(err, info)
        got.err = err
        got.info = info
        got.done = { err = err, info = info }
      end,
    })
    H.ok(handle ~= nil, "live operation started")
    return got
  end

  ---Run one live agent operation and wait for its terminal callback.
  local function run(proj, question)
    local got = run_start(proj, question)
    local settled = vim.wait(600000, function()
      return got.done ~= nil
    end, 50)
    H.ok(settled, "live operation settled within the wall-clock bound")
    return got
  end

  H.test("a plain question streams content deltas and reports provider usage", function()
    configure("plain")
    local proj = fixture("plain")
    local got = run(proj, "What is 2 + 2? Answer in one short sentence.")
    H.eq(got.done.err, nil, "no error")
    H.ok(got.done.info.content and #got.done.info.content > 0, "answer content present")
    H.ok(got.deltas > 1, "content arrived as multiple streamed deltas (got " .. got.deltas .. ")")
    local u = got.done.info.usage
    H.ok(u and u.reported_input > 0 and u.reported_output > 0, "provider reported token usage")
  end)

  H.test("a native tool roundtrip runs the scoped read-only tools", function()
    configure("tools")
    local proj = fixture("tools")
    local got =
      run(proj, "Use your tools: list the project directory, read main.lua, then tell me what it prints.")
    H.eq(got.done.err, nil, "no error")
    H.ok(#got.tools >= 1, "at least one tool executed")
    -- Model-side misuse (bad arguments, wrong tool choice, out-of-scope path)
    -- is correct pipeline behavior and self-corrects via hint-bearing errors;
    -- plugin-side breakage in the tool layer never is and must fail here.
    local internal_failures = {
      "tool failed:",
      "tool produced no structured result",
      "operation was cancelled",
      "exceeded its time budget",
    }
    local succeeded = 0
    for _, tool in ipairs(got.tools) do
      if tool.ok then
        succeeded = succeeded + 1
      else
        local err = tool.error or ""
        local internal = false
        for _, sig in ipairs(internal_failures) do
          if err:find(sig, 1, true) then
            internal = true
            break
          end
        end
        H.ok(not internal, "tool " .. tool.name .. " failed inside the plugin: " .. err)
      end
    end
    H.ok(succeeded >= 1, "at least one tool call succeeded")
    H.contains_text((got.done.info.content or ""):lower(), "hello", "answer reflects tool output")
  end)

  H.test("excluded credential contents never reach any outbound request body", function()
    -- Bodies from every prior operation are already recorded; plus ask the
    -- model directly about the secret so it is likely to try reading it.
    configure("privacy")
    local proj = fixture("privacy")
    local got = run(
      proj,
      "What environment configuration does this project define? Check the .env file in the project root with your tools and quote what you find."
    )
    H.eq(got.done.err, nil, "operation completed (a denied tool result is fine)")
    local denied = false
    for _, body in ipairs(bodies) do
      H.ok(not body:find(SECRET_MARKER, 1, true), "no outbound body carries the excluded secret")
      if body:find("excluded by access policy", 1, true) or body:find("withheld", 1, true) then
        denied = true
      end
    end
    H.ok(denied, "the denial was reported back into the conversation")
  end)

  H.test("two concurrent operations share one transport slot and both finish", function()
    configure("queue")
    local proj = fixture("queue")
    local first, second
    first = run_start(proj, "Answer with exactly one word: apple.")
    second = run_start(proj, "Answer with exactly one word: banana.")
    local ok = vim.wait(600000, function()
      return first.done ~= nil and second.done ~= nil
    end, 50)
    H.ok(ok, "both operations settled")
    H.eq(first.err, nil, "first ok")
    H.eq(second.err, nil, "second ok")
    H.eq(max_inflight, 1, "never more than one request in flight for one endpoint")
  end)
end
