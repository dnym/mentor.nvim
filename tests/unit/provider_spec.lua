-- Unit: the OpenAI-compatible adapter driven through a scripted transport.
-- Verifies incremental SSE normalization, tool-call assembly and validation,
-- provider error bodies, accumulation caps, non-streaming parsing, and the
-- per-endpoint single-flight queue. No network.

local H = require("tests.support.harness")
local openai = require("mentor.provider.openai")
local scheduler = require("mentor.scheduler")

local function base_settings(overrides)
  return vim.tbl_extend("force", {
    endpoint = "http://provider.test/v1",
    model = "test-model",
    api_key_env = "",
    timeout_s = 5,
    max_tokens = 256,
    capabilities = { tools = true, streaming = true },
  }, overrides or {})
end

---Scripted transport: records requests; the test drives chunks/exit by hand.
local function fake_transport()
  local T = { requests = {}, started = 0, finished = 0 }
  function T.check()
    return nil
  end
  function T.request(req)
    local entry = { req = req, cancelled = false, settled = false }
    local h = { active = true }
    function h:cancel()
      if entry.settled then
        return
      end
      entry.cancelled = true
      entry.settled = true
      T.finished = T.finished + 1
      h.active = false
      req.on_exit("cancelled", nil)
    end
    function h:is_active()
      return not entry.settled
    end
    entry.handle = h
    T.started = T.started + 1
    T.requests[#T.requests + 1] = entry
    return h
  end
  ---Settle request n with an exit kind after optionally feeding chunks;
  ---curl_code is the numeric exit code the real transport would attach.
  function T.settle(n, chunks, exit_code, curl_code)
    local entry = T.requests[n]
    for _, chunk in ipairs(chunks or {}) do
      entry.req.on_delta(chunk)
    end
    entry.settled = true
    T.finished = T.finished + 1
    entry.handle.active = false
    entry.req.on_exit(exit_code, curl_code)
  end
  return T
end

local function with_transport(fn)
  local transport = fake_transport()
  local real = openai._transport
  local old_cap = openai.max_response_bytes
  openai._transport = transport
  local ok, err = pcall(fn, transport)
  openai._transport = real
  openai.max_response_bytes = old_cap
  scheduler.reset()
  if not ok then
    error(err)
  end
  return transport
end

return function()
  H.test("content deltas stream, reasoning deltas do not, tool calls assemble", function()
    with_transport(function(transport)
      local deltas = {}
      local done
      openai.chat({
        settings = base_settings(),
        messages = { { role = "user", content = "read it" } },
        on_delta = function(chunk)
          deltas[#deltas + 1] = chunk
        end,
        on_done = function(err, info)
          done = { err = err, info = info }
        end,
      })
      local stream = table.concat({
        'data: {"choices":[{"index":0,"delta":{"reasoning_content":"hidden thoughts"}}]}\n\n',
        'data: {"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"index":0,"delta":{"content":"lo world"},"finish_reason":null}]}\n\n',
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1",',
        '"function":{"name":"read_file","arguments":"{\\"path\\":\\""}}]}}]}\n\n',
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,',
        '"function":{"arguments":"main.c\\"}"}}]}}]}\n\n',
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"c2",',
        '"function":{"name":"get_git_status","arguments":"{}"}}]}}]}\n\n',
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\n',
        'data: {"choices":[],"usage":{"prompt_tokens":40,"completion_tokens":20}}\n\n',
        "data: [DONE]\n\n",
      })
      local pos = 1
      local chunks = {}
      while pos <= #stream do
        local size = math.min(13, #stream - pos + 1)
        chunks[#chunks + 1] = stream:sub(pos, pos + size - 1)
        pos = pos + size
      end
      transport.settle(1, chunks, nil)
      H.ok(done, "terminal callback fired")
      H.eq(done.err, nil, "no error")
      H.eq(table.concat(deltas), "Hello world", "answer content streamed in order")
      H.ok(
        not table.concat(deltas):find("hidden", 1, true)
          and not vim.inspect(done.info):find("hidden", 1, true),
        "reasoning content never surfaces"
      )
      H.eq(done.info.finish_reason, "tool_calls", "finish reason captured")
      H.eq(#done.info.tool_calls, 2, "two calls assembled")
      H.eq(done.info.tool_calls[1].id, "c1", "call id")
      H.eq(done.info.tool_calls[1].name, "read_file", "name from fragments")
      H.eq(done.info.tool_calls[1].arguments, { path = "main.c" }, "arguments decoded across fragments")
      H.eq(done.info.tool_calls[2].name, "get_git_status", "second call")
      H.eq(done.info.usage, { input = 40, output = 20 }, "usage captured")
    end)
  end)

  H.test("incomplete streamed tool calls are refused, never executed", function()
    with_transport(function(transport)
      local done
      openai.chat({
        settings = base_settings(),
        messages = { { role = "user", content = "go" } },
        on_done = function(err, info)
          done = { err = err, info = info }
        end,
      })
      transport.settle(1, {
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\\"pa"}}]}}]}\n\n',
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}\n\n',
        "data: [DONE]\n\n",
      }, nil)
      H.eq(done.err, "malformed_response", "incomplete call flagged")
      H.contains_text(done.info.message, "incomplete", "actionable message")
    end)
  end)

  H.test("provider error bodies become actionable classified errors", function()
    with_transport(function(transport)
      local done
      openai.chat({
        settings = base_settings(),
        messages = { { role = "user", content = "go" } },
        on_done = function(err, info)
          done = { err = err, info = info }
        end,
      })
      -- --fail-with-body: the error body arrives on stdout, exit 22.
      transport.settle(
        1,
        { '{"error":{"type":"invalid_request_error","message":"model not found"}}' },
        "http_error"
      )
      H.eq(done.err, "request_rejected", "deterministic rejection is not retryable")
      H.contains_text(done.info.message, "model not found", "provider message surfaced")

      local done2
      openai.chat({
        settings = base_settings({ endpoint = "http://other.test/v1" }),
        messages = { { role = "user", content = "go" } },
        on_done = function(err, info)
          done2 = { err = err, info = info }
        end,
      })
      transport.settle(2, { '{"error":{"type":"server_error","message":"busy"}}' }, "http_error")
      H.eq(done2.err, "http_error", "server errors stay transient-class")
    end)
  end)

  H.test("transport failures name the likely cause", function()
    with_transport(function(transport)
      local done
      openai.chat({
        settings = base_settings(),
        messages = { { role = "user", content = "go" } },
        on_done = function(err, info)
          done = { err = err, info = info }
        end,
      })
      transport.settle(1, {}, "transport_error", 7)
      H.eq(done.err, "transport_error", "connection failure keeps its transient class")
      H.contains_text(done.info.message, "refused the connection", "cause named")
      H.contains_text(done.info.message, "provider.endpoint", "config pointed at")

      local done2
      openai.chat({
        settings = base_settings(),
        messages = { { role = "user", content = "go" } },
        on_done = function(err, info)
          done2 = { err = err, info = info }
        end,
      })
      transport.settle(2, {}, "timeout")
      H.eq(done2.err, "timeout", "timeout class preserved")
      H.contains_text(done2.info.message, "timed out", "plain-language timeout")
      H.contains_text(done2.info.message, "provider.timeout_s", "remedy offered")

      local done3
      openai.chat({
        settings = base_settings(),
        messages = { { role = "user", content = "go" } },
        on_done = function(err, info)
          done3 = { err = err, info = info }
        end,
      })
      transport.settle(3, {}, "transport_error", 92)
      H.contains_text(done3.info.message, "curl exit 92", "unknown codes report the code")
      H.contains_text(done3.info.message, "checkhealth", "diagnostics pointed at")
    end)
  end)

  ---Start one chat and return a table that receives the terminal result.
  local function start_chat(settings)
    local done = {}
    openai.chat({
      settings = settings or base_settings(),
      messages = { { role = "user", content = "go" } },
      on_done = function(err, info)
        done.err, done.info, done.settled = err, info, true
      end,
    })
    return done
  end

  ---One SSE event carrying a content (or reasoning) delta, with the bulky
  ---per-token framing real servers send.
  local function sse_delta(field, text)
    local framing = ("f"):rep(200)
    return string.format(
      'data: {"id":"chatcmpl-%s","object":"chat.completion.chunk","created":1,"model":"m",'
        .. '"choices":[{"index":0,"delta":{"%s":%s}}]}\n\n',
      framing,
      field,
      vim.json.encode(text)
    )
  end

  H.test("the response cap counts produced payload, not stream framing", function()
    with_transport(function(transport)
      openai.max_response_bytes = 1024
      local done = start_chat()
      -- 100 one-token events: ~25 KiB of SSE, but only 100 bytes of content.
      local chunks = {}
      for _ = 1, 100 do
        chunks[#chunks + 1] = sse_delta("content", "x")
      end
      chunks[#chunks + 1] = "data: [DONE]\n\n"
      transport.settle(1, chunks, nil)
      H.eq(done.err, nil, "framing-heavy stream under the payload cap succeeds")
      H.eq(done.info.content, ("x"):rep(100), "content assembled")
    end)
  end)

  H.test("content, reasoning, and tool arguments all count against the cap", function()
    for _, field in ipairs({ "content", "reasoning_content" }) do
      with_transport(function(transport)
        openai.max_response_bytes = 256
        local done = start_chat()
        transport.settle(1, { sse_delta(field, ("y"):rep(300)), "data: [DONE]\n\n" }, nil)
        H.eq(done.err, "response_too_large", field .. " over the cap is refused")
        H.contains_text(done.info.message, "accumulation cap", "message names the cap")
      end)
    end
    with_transport(function(transport)
      openai.max_response_bytes = 256
      local done = start_chat()
      local args = vim.json.encode({ replacement = ("z"):rep(300) })
      transport.settle(1, {
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1",'
          .. '"function":{"name":"propose_edit","arguments":'
          .. vim.json.encode(args)
          .. "}}]}}]}\n\n",
        "data: [DONE]\n\n",
      }, nil)
      H.eq(done.err, "response_too_large", "tool-call arguments over the cap are refused")
    end)
  end)

  H.test("a raw stream guard still stops endless framing", function()
    with_transport(function(transport)
      local old = openai.max_stream_bytes
      openai.max_stream_bytes = 4096
      local done = start_chat()
      local chunks = {}
      for _ = 1, 100 do
        chunks[#chunks + 1] = ": keep-alive " .. ("k"):rep(100) .. "\n\n"
      end
      transport.settle(1, chunks, nil)
      openai.max_stream_bytes = old
      H.eq(done.err, "response_too_large", "keep-alive flood is refused")
      H.contains_text(done.info.message, "raw stream cap", "message names the raw guard")
    end)
  end)

  H.test("non-streaming bodies keep the raw cap", function()
    with_transport(function(transport)
      openai.max_response_bytes = 256
      local done = start_chat(base_settings({ capabilities = { tools = true, streaming = false } }))
      transport.settle(1, { ("x"):rep(300) }, nil)
      H.eq(done.err, "response_too_large", "cap enforced on the body")
    end)
  end)

  H.test("streamed error bodies are still read after the cap change", function()
    with_transport(function(transport)
      local done = start_chat()
      transport.settle(1, { '{"error":{"message":"model not found"}}' }, "http_error")
      H.ok(done.settled and done.err ~= nil, "error delivered")
      H.contains_text(done.info.message, "model not found", "provider message surfaced")
    end)
  end)

  H.test("non-streaming mode parses the complete response object", function()
    with_transport(function(transport)
      local done
      openai.chat({
        settings = base_settings({ capabilities = { tools = true, streaming = false } }),
        messages = { { role = "user", content = "go" } },
        on_done = function(err, info)
          done = { err = err, info = info }
        end,
      })
      H.contains_text(transport.requests[1].req.body, '"stream":false', "stream flag off")
      transport.settle(1, {
        '{"choices":[{"message":{"role":"assistant","content":"plain answer",',
        '"tool_calls":[{"id":"t1","function":{"name":"read_file","arguments":"{\\"path\\":\\"a\\"}"}}]},',
        '"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":7}}',
      }, nil)
      H.eq(done.err, nil, "parsed")
      H.eq(done.info.content, "plain answer", "content")
      H.eq(done.info.tool_calls[1].arguments, { path = "a" }, "tool call parsed")
      H.eq(done.info.usage, { input = 3, output = 7 }, "usage")
    end)
  end)

  H.test("requests to one endpoint run one at a time in order; different endpoints overlap", function()
    with_transport(function(transport)
      local order = {}
      local function ask(endpoint, tag)
        return openai.chat({
          settings = base_settings({ endpoint = endpoint }),
          messages = { { role = "user", content = tag } },
          on_done = function()
            order[#order + 1] = tag
          end,
        })
      end
      ask("http://single.test/v1", "first")
      local second = ask("http://single.test/v1", "second")
      ask("http://parallel.test/v1", "other")
      H.eq(transport.started, 2, "second same-endpoint request stays queued")
      transport.settle(
        1,
        { 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n' },
        nil
      )
      H.eq(transport.started, 3, "queue released the second request")
      transport.settle(
        2,
        { 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n' },
        nil
      )
      transport.settle(
        3,
        { 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n' },
        nil
      )
      H.eq(order, { "first", "other", "second" }, "FIFO per endpoint, parallel across endpoints")
      H.ok(second, "handle returned")
    end)
  end)

  H.test("cancelling a queued request never starts its transport", function()
    with_transport(function(transport)
      local first_done, second_done
      openai.chat({
        settings = base_settings(),
        messages = { { role = "user", content = "one" } },
        on_done = function(err)
          first_done = err or "ok"
        end,
      })
      local queued = openai.chat({
        settings = base_settings(),
        messages = { { role = "user", content = "two" } },
        on_done = function(err)
          second_done = err
        end,
      })
      queued:cancel()
      H.eq(transport.started, 1, "queued request never started")
      transport.settle(
        1,
        { 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n' },
        nil
      )
      H.eq(first_done, "ok", "first completed")
      H.eq(second_done, "cancelled", "queued cancellation reports cancellation")
    end)
  end)

  H.test("an empty stream and undecodable chunks are reported as malformed", function()
    with_transport(function(transport)
      local done
      openai.chat({
        settings = base_settings(),
        messages = { { role = "user", content = "go" } },
        on_done = function(err)
          done = err
        end,
      })
      transport.settle(1, {}, nil)
      H.eq(done, "no_response", "empty stream")

      local done2
      openai.chat({
        settings = base_settings({ endpoint = "http://other2.test/v1" }),
        messages = { { role = "user", content = "go" } },
        on_done = function(err)
          done2 = err
        end,
      })
      transport.settle(2, { "data: <<not json>>\n\n" }, nil)
      H.eq(done2, "malformed_response", "undecodable chunk")
    end)
  end)

  H.test("HTTP errors retry only for transient statuses", function()
    with_transport(function(transport)
      local function outcome(n, status, body)
        local done
        openai.chat({
          settings = base_settings({ endpoint = "http://status" .. n .. ".test/v1" }),
          messages = { { role = "user", content = "go" } },
          on_done = function(err, info)
            done = { err = err, info = info }
          end,
        })
        local entry = transport.requests[n]
        for _, chunk in ipairs({ body }) do
          entry.req.on_delta(chunk)
        end
        entry.settled = true
        entry.handle.active = false
        entry.req.on_exit("http_error", 22, status)
        return done
      end
      local auth = outcome(1, 401, '{"error":{"type":"authentication_error","message":"bad key"}}')
      H.eq(auth.err, "request_rejected", "401 is deterministic")
      H.contains_text(auth.info.message, "HTTP 401", "status shown")
      H.contains_text(auth.info.message, "api_key_env", "remedy named")
      local missing = outcome(2, 404, '{"error":{"type":"not_found_error","message":"nope"}}')
      H.eq(missing.err, "request_rejected", "404 is deterministic")
      H.contains_text(missing.info.message, "provider.endpoint", "remedy named")
      local overflow = outcome(3, 400, '{"error":{"type":"exceed_context_size_error","message":"too long"}}')
      H.eq(overflow.err, "request_rejected", "400 is deterministic whatever its type")
      H.eq(outcome(4, 429, '{"error":{"message":"slow down"}}').err, "http_error", "429 retries")
      H.eq(outcome(5, 503, '{"error":{"message":"loading"}}').err, "http_error", "5xx retries")
    end)
  end)

  H.test("streaming requests ask for an event stream", function()
    with_transport(function(transport)
      openai.chat({
        settings = base_settings({ endpoint = "http://accept.test/v1" }),
        messages = { { role = "user", content = "go" } },
        on_done = function() end,
      })
      H.contains_text(
        table.concat(transport.requests[1].req.headers, "\n"),
        "Accept: text/event-stream",
        "accept header"
      )
      transport.settle(1, {}, "cancelled")
    end)
  end)
end
