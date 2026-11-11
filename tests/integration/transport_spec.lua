-- Integration: curl subprocess transport with incremental delivery.
-- Uses file:// URLs so no network or credentials are involved; the same
-- plumbing (fixed argv, stdin config, chunk callbacks) serves HTTP in M3.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local transport = require("mentor.provider.transport")

return function()
  H.test("queued response chunks arrive before a fast process exit", function()
    local saved = vim.system
    local events = {}
    vim.system = function(_, opts, on_exit)
      opts.stdout(nil, "last chunk")
      on_exit({ code = 0 })
      return { kill = function() end }
    end
    local handle = transport.request({
      url = "file:///dev/null",
      on_delta = function(chunk)
        events[#events + 1] = chunk
      end,
      on_exit = function()
        events[#events + 1] = "exit"
      end,
    })
    vim.system = saved
    H.ok(handle, "request started")
    vim.wait(1000, function()
      return #events == 2
    end, 5)
    H.eq(table.concat(events, ","), "last chunk,exit", "chunk delivered before exit")
  end)
  H.test("missing transport executable produces an actionable error", function()
    local saved = transport.executable
    transport.executable = "mentor-curl-definitely-missing"
    local handle, err = transport.request({ url = "file:///etc/hostname" })
    transport.executable = saved
    H.ok(handle == nil, "no handle returned")
    H.contains_text(err, "curl", "error names the missing dependency")
  end)

  H.test("a request delivers response chunks incrementally", function()
    local path = fs.write(
      fs.tmpdir() .. "/payload.txt",
      table.concat({
        "line one",
        "line two",
        "line three " .. string.rep("pad", 500),
        "last line",
      }, "\n")
    )
    local deltas, exits = {}, {}
    local handle, err = transport.request({
      url = "file://" .. path,
      headers = { "X-Test: transport-check" },
      timeout_s = 10,
      on_delta = function(chunk)
        deltas[#deltas + 1] = chunk
      end,
      on_exit = function(e, code)
        exits[#exits + 1] = { err = e, code = code }
      end,
    })
    H.ok(handle, "request started")
    local finished = vim.wait(5000, function()
      return #exits > 0
    end, 5)
    H.ok(finished, "request completed")
    H.eq(exits[1].err, nil, "no error")
    H.eq(exits[1].code, 0, "exit code 0")
    local body = table.concat(deltas, "")
    H.contains_text(body, "line one", "first line delivered")
    H.contains_text(body, "last line", "final line delivered")
    H.ok(#deltas >= 1, "delta callback fired at least once (chunks: " .. #deltas .. ")")
    H.ok(not handle:is_active(), "handle inactive after completion")
  end)

  H.test("a request body travels through a protected spool file, not argv", function()
    -- file:// uploads are refused by curl; the transport error proves the
    -- process ran with a body configured, while argv inspection below proves
    -- the secret never appears in the argument vector.
    local seen_argv ---@type string[]|nil
    local saved_spawn = vim.system
    vim.system = function(argv, opts)
      seen_argv = argv
      return saved_spawn(argv, opts)
    end
    local exits = {}
    local handle, err = transport.request({
      url = "file:///dev/null",
      body = "super-secret-unsaved-code",
      on_exit = function(e)
        exits[#exits + 1] = e
      end,
    })
    H.ok(handle, "request started: " .. tostring(err))
    vim.wait(3000, function()
      return #exits > 0
    end, 5)
    vim.system = saved_spawn
    H.ok(seen_argv, "intercepted argv")
    for _, a in ipairs(seen_argv) do
      H.ok(not tostring(a):find("super-secret", 1, true), "secret absent from argv: " .. a)
    end
  end)
end
