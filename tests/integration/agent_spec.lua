-- Integration: the bounded agent loop driven by scripted providers against
-- fixture repositories. Covers the tool roundtrip, budget and limit stops,
-- policy rechecks that withhold newly excluded sources, cancellation, the
-- single transient retry, and usage accounting. No network.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local mentor = require("mentor")
local project = require("mentor.project")
local agent = require("mentor.agent")
local fake = require("mentor.provider.fake")
local storage = require("mentor.storage")
local records = require("mentor.storage.records")

return function()
  ---Isolated environment; returns the fixture project.
  local function configure(label, extra_config)
    mentor.shutdown()
    storage.close()
    agent.provider = nil
    fake._scripted = nil
    fake.chunk_delay_ms = 1
    local opts = {
      dev = { fake_provider = true },
      data_dir = fs.tmpdir() .. "/data-agent-" .. label,
    }
    for k, v in pairs(extra_config or {}) do
      opts[k] = v
    end
    mentor.setup(opts)
    local dir = fs.git_repo(fs.tmpdir() .. "/agent-" .. label)
    fs.write(dir .. "/main.lua", "print('work in progress')\n")
    return project.for_dir(dir)
  end

  ---Runs one operation with scripted turns and waits for the terminal callback.
  local function run_operation(proj, turns, extra)
    fake.script(turns)
    local captured = { deltas = {}, messages = {}, notes = {}, tools = {} }
    local opts = {
      mode = "coach",
      project = proj,
      messages = {
        { role = "system", content = "test prompt" },
        { role = "user", content = "what does main.lua do?" },
      },
      on_delta = function(chunk)
        captured.deltas[#captured.deltas + 1] = chunk
      end,
      on_message = function(msg)
        captured.messages[#captured.messages + 1] = msg
      end,
      on_note = function(text)
        captured.notes[#captured.notes + 1] = text
      end,
      on_tool = function(phase, call, result)
        captured.tools[#captured.tools + 1] = { phase = phase, name = call.name, ok = result and result.ok }
      end,
      on_done = function(err, info)
        captured.done = { err = err, info = info }
      end,
    }
    for k, v in pairs(extra or {}) do
      opts[k] = v
    end
    local handle = agent.run(opts)
    H.ok(handle, "operation started")
    captured.handle = handle
    local ok = vim.wait(5000, function()
      return captured.done ~= nil
    end, 5)
    H.ok(ok, "operation settled in time")
    return captured
  end

  H.test("a tool roundtrip executes the approved tool and reaches an answer", function()
    local proj = configure("roundtrip")
    local captured = run_operation(proj, {
      {
        content = "let me inspect",
        tool_calls = { { name = "read_file", arguments = { path = "main.lua" } } },
      },
      { content = "it prints a placeholder" },
    })
    H.eq(captured.done.err, nil, "no error")
    H.eq(captured.done.info.stop_reason, "stop", "natural stop")
    H.contains_text(table.concat(captured.deltas), "it prints a placeholder", "answer streamed")
    H.eq(#captured.messages, 3, "assistant, tool, assistant recorded")
    H.eq(captured.messages[1].tool_calls[1].name, "read_file", "assistant turn carries the call")
    H.contains_text(captured.messages[2].content, "work in progress", "tool result content")
    H.contains_text(captured.messages[2].source, "main.lua", "tool provenance recorded")
    H.eq(captured.messages[3].content, "it prints a placeholder", "final assistant turn")
    H.eq(captured.tools[1].phase .. "/" .. captured.tools[1].name, "start/read_file", "activity events")
    H.ok(captured.tools[2].ok, "tool succeeded")
    local totals =
      records.usage.totals(records.projects.get(proj.identity).id, records.usage.today(), "interactive")
    H.eq(totals.model_requests, 2, "both model requests accounted")
    H.eq(totals.open_reservations, 0, "no reservations left open")
  end)

  H.test("the model request limit stops the loop with an explanation", function()
    local proj = configure("model-limit", {
      limits = { interactive = { model_requests = 2, tool_calls = 16 } },
    })
    local call = { name = "read_file", arguments = { path = "main.lua" } }
    local captured = run_operation(proj, {
      { content = "", tool_calls = { call } },
      { content = "", tool_calls = { call } },
      { content = "should never run", tool_calls = { call } },
    })
    H.eq(captured.done.err, nil, "soft stop, not an error")
    H.contains_text(captured.done.info.stop_reason, "model request limit", "limit explained")
    H.contains_text(captured.done.info.stop_reason, "2", "limit value shown")
  end)

  H.test("the tool call budget stops the loop with an explanation", function()
    local proj = configure("tool-limit", {
      limits = { interactive = { model_requests = 8, tool_calls = 1 } },
    })
    local call = { name = "read_file", arguments = { path = "main.lua" } }
    local captured = run_operation(proj, {
      { content = "", tool_calls = { call } },
      { content = "", tool_calls = { call } },
      { content = "never" },
    })
    H.contains_text(captured.done.info.stop_reason, "tool call limit", "limit explained")
    H.eq(#captured.tools / 2, 1, "exactly one tool executed")
  end)

  H.test("a policy change mid-operation stops transmitting the excluded source", function()
    local proj = configure("policy-recheck")
    -- Capture exactly what each dispatch would send to the provider.
    local dispatched = {}
    agent.provider = {
      chat = function(req)
        dispatched[#dispatched + 1] = req.messages
        return fake.chat(req)
      end,
    }
    run_operation(proj, {
      { content = "", tool_calls = { { name = "read_file", arguments = { path = "main.lua" } } } },
      { content = "second turn" },
    })
    H.eq(#dispatched, 2, "two dispatches captured")
    H.contains_text(vim.inspect(dispatched[2]), "work in progress", "second dispatch replays the tool result")

    -- Widen exclusions and replay the stored conversation: a tool result
    -- whose source became excluded must be withheld from every request.
    require("mentor.config").load({
      dev = { fake_provider = true },
      data_dir = fs.tmpdir() .. "/data-agent-policy-recheck",
      context = { exclusions = { "main.lua" } },
    })
    fake.script({ { content = "third turn" } })
    local done2
    local handle = agent.run({
      mode = "coach",
      project = proj,
      messages = {
        { role = "system", content = "test prompt" },
        { role = "user", content = "what does main.lua do now?" },
        {
          role = "tool",
          tool_call_id = "prior1",
          content = '{"ok":true,"content":"work in progress"}',
          source = "main.lua",
        },
      },
      on_done = function(err, info)
        done2 = { err = err, info = info }
      end,
    })
    H.ok(handle, "second operation started")
    vim.wait(5000, function()
      return done2 ~= nil
    end, 5)
    agent.provider = nil

    H.ok(done2, "second operation settled")
    local last = dispatched[#dispatched]
    H.contains_text(vim.inspect(last), "withheld", "newly excluded source is withheld")
    H.ok(not vim.inspect(last):find("work in progress", 1, true), "excluded content never transmitted")
  end)

  H.test("multi-file result provenance is rechecked after exclusions change", function()
    local proj = configure("multi-provenance")
    local provenance = require("mentor.provenance")
    local ctx = require("mentor.tools").new_operation({ project = proj })
    local source = provenance.capture(ctx, {}, { matches = { { path = "main.lua", text = "private" } } })
    H.ok(provenance.authorized(source, "search_content", ctx.policy), "initially authorized")
    require("mentor.config").load({ context = { exclusions = { "main.lua" } } })
    local policy = require("mentor.policy").for_project(proj)
    H.ok(not provenance.authorized(source, "search_content", policy), "new exclusion withholds result")
    H.ok(not provenance.authorized(nil, "search_content", policy), "legacy multi-file result withheld")
  end)

  H.test("estimated token budget stops with an explanation", function()
    local proj = configure("token-budget", {
      limits = { interactive = { model_requests = 8, tool_calls = 16, est_tokens = 10 } },
    })
    local captured = run_operation(proj, { { content = "never dispatched" } })
    H.contains_text(captured.done.info.stop_reason, "per-request budget", "budget explained")
    local totals =
      records.usage.totals(records.projects.get(proj.identity).id, records.usage.today(), "interactive")
    H.eq(totals.model_requests, 0, "nothing was dispatched or charged")
  end)

  H.test("cancellation ends the operation and retains conservative usage", function()
    local proj = configure("cancel")
    fake.chunk_delay_ms = 15
    local long = {}
    for i = 1, 80 do
      long[i] = "tok" .. i
    end
    fake.script({ table.concat(long, " ") })
    local captured = { done = nil }
    local handle = agent.run({
      mode = "coach",
      project = proj,
      messages = { { role = "user", content = "stream something long" } },
      on_delta = function() end,
      on_done = function(err, info)
        captured.done = { err = err, info = info }
      end,
    })
    vim.wait(120)
    handle:cancel()
    vim.wait(1000, function()
      return captured.done ~= nil
    end, 5)
    H.ok(captured.done, "terminal callback arrived")
    H.eq(captured.done.err, "cancelled", "cancellation reported")
    local totals =
      records.usage.totals(records.projects.get(proj.identity).id, records.usage.today(), "interactive")
    H.eq(totals.model_requests, 1, "dispatched work stays charged conservatively")
  end)

  H.test("one transient retry is automatic, then the failure surfaces", function()
    local proj = configure("retry-ok")
    local attempts = 0
    agent.provider = {
      chat = function(req)
        attempts = attempts + 1
        if attempts == 1 then
          vim.schedule(function()
            req.on_done("timeout", { message = "provider timed out" })
          end)
        else
          req.on_start()
          req.on_done(nil, { content = "recovered", finish_reason = "stop" })
        end
        return {
          cancel = function() end,
          is_active = function()
            return false
          end,
        }
      end,
    }
    local captured = run_operation(proj, {})
    agent.provider = nil
    H.eq(captured.done.err, nil, "second attempt succeeded")
    H.contains_text(captured.done.info.content, "recovered", "answer present")
    H.eq(#captured.notes, 1, "retry notice emitted")
    H.eq(attempts, 2, "exactly one retry")
    local totals =
      records.usage.totals(records.projects.get(proj.identity).id, records.usage.today(), "interactive")
    -- The first attempt never marked itself dispatched, so its reservation
    -- releases; only the attempt that actually ran stays charged.
    H.eq(totals.model_requests, 1, "only the dispatched attempt is charged")
    H.eq(totals.open_reservations, 0, "nothing left open")
  end)

  H.test("deterministic provider rejections end without retry", function()
    local proj = configure("reject")
    local attempts = 0
    agent.provider = {
      chat = function(req)
        attempts = attempts + 1
        req.on_start()
        req.on_done("request_rejected", { message = "provider rejected the request: bad model" })
        return {
          cancel = function() end,
          is_active = function()
            return false
          end,
        }
      end,
    }
    local captured = run_operation(proj, {})
    agent.provider = nil
    H.eq(attempts, 1, "no retry on deterministic rejection")
    H.eq(captured.done.err, "request_rejected", "error surfaced")
    H.contains_text(captured.done.info.message, "bad model", "provider message carried")
  end)

  H.test("the token budget caps each request, not the cumulative context", function()
    -- Each request reports 1500 input tokens: the cumulative spend passes the
    -- 4000-token cap after three requests, but no single request comes close.
    local proj = configure("per-request-budget", {
      limits = { interactive = { model_requests = 8, tool_calls = 16, est_tokens = 4000 } },
    })
    local requests = 0
    agent.provider = {
      chat = function(req)
        requests = requests + 1
        local n = requests
        vim.schedule(function()
          req.on_start()
          local usage = { input = 1500, output = 10 }
          if n <= 3 then
            req.on_done(nil, {
              content = "",
              usage = usage,
              tool_calls = {
                {
                  id = "c" .. n,
                  name = "read_file",
                  arguments = { path = "main.lua" },
                  raw = '{"path":"main.lua"}',
                },
              },
            })
          else
            req.on_done(nil, { content = "done after four requests", finish_reason = "stop", usage = usage })
          end
        end)
        return {
          cancel = function() end,
          is_active = function()
            return false
          end,
        }
      end,
    }
    local captured = run_operation(proj, {})
    agent.provider = nil
    H.eq(captured.done.err, nil, "no error")
    H.eq(captured.done.info.stop_reason, "stop", "natural stop, not a budget stop")
    H.eq(requests, 4, "all four requests ran")
    H.ok(captured.done.info.usage.estimated_tokens > 4000, "cumulative spend exceeded the per-request cap")
  end)
end
