-- Env-gated live verification of the Observer pipeline against a real
-- OpenAI-compatible endpoint (skipped unless the environment asks for it):
--
--   MENTOR_LIVE_ENDPOINT=http://host:port/v1 MENTOR_LIVE_MODEL=<model> make live-test
--
-- It drives an explicit review pass end to end: the change digest built
-- from real Git state must reach the model, the native tool roundtrip
-- through report_observations must complete over real SSE, background
-- usage must be accounted, and policy-excluded file contents must never
-- appear in any outbound request body (including unsaved buffer content).

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local mentor = require("mentor")
local project = require("mentor.project")
local agent = require("mentor.agent")
local storage = require("mentor.storage")
local records = require("mentor.storage.records")
local observer = require("mentor.observer")
local openai = require("mentor.provider.openai")
local real_transport = require("mentor.provider.transport")

local SECRET_MARKER = "LIVE-OBS-SECRET-MARKER-4e8ac2"
local CHANGE_MARKER = "live-obs-change-marker-6db91"

local endpoint = vim.env.MENTOR_LIVE_ENDPOINT
local model = vim.env.MENTOR_LIVE_MODEL

return function()
  if not endpoint or endpoint == "" or not model or model == "" then
    io.write("observer live check skipped: set MENTOR_LIVE_ENDPOINT and MENTOR_LIVE_MODEL to run it\n")
    return
  end
  if real_transport.check() then
    H.ok(false, "curl transport unavailable for live check")
    return
  end

  -- Spy transport: record every outbound body at the transport boundary.
  local bodies = {}
  local spy = { check = real_transport.check }
  function spy.request(req)
    bodies[#bodies + 1] = req.body or ""
    return real_transport.request(req)
  end
  openai._transport = spy

  ---Fixture repo whose uncommitted edit carries a recognizable marker and
  ---an obvious arity bug, plus an excluded credential file.
  local function fixture(label)
    local dir = fs.git_repo(fs.tmpdir() .. "/live-obs-" .. label)
    fs.write(
      dir .. "/main.lua",
      "local function handle(value)\n  return value + 1\nend\n\nprint(handle(2))\n"
    )
    fs.commit(dir, "fixture baseline")
    fs.write(
      dir .. "/main.lua",
      -- The marker rides inside the diff sent to the model.
      "local function handle(value, "
        .. CHANGE_MARKER
        .. "_opts)\n  return value + ("
        .. CHANGE_MARKER
        .. "_opts and 2 or 1)\nend\n\nprint(handle(2))\n"
    )
    fs.write(dir .. "/.env", "API_KEY=" .. SECRET_MARKER .. "\n")
    return project.for_dir(dir)
  end

  local function configure(label)
    mentor.shutdown()
    storage.close()
    observer._reset()
    agent.provider = nil
    vim.cmd("silent! only")
    mentor.setup({
      dev = { fake_provider = false },
      data_dir = fs.tmpdir() .. "/data-live-obs-" .. label,
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
      limits = { background = { elapsed_s = 600, model_requests = 6, tool_calls = 12 } },
    })
  end

  H.test("an explicit review pass runs against the real endpoint and reports back", function()
    configure("review")
    local proj = fixture("review")
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/main.lua"))

    local ok = observer.review(proj)
    H.ok(ok, "review accepted (explicit request path, no activation needed)")
    local settled = vim.wait(600000, function()
      return observer._internals.is_running() == nil
    end, 50)
    H.ok(settled, "the pass settled within the wall-clock bound")

    local pid = records.projects.get(proj.identity).id
    local totals = records.usage.totals(pid, records.usage.today(), "background")
    H.ok(totals.model_requests >= 1, "background usage was accounted")
    H.ok(#bodies >= 1, "at least one request reached the endpoint")

    local digest_seen, roundtrip = false, false
    for _, body in ipairs(bodies) do
      if body:find(CHANGE_MARKER, 1, true) then
        digest_seen = true
      end
      if body:find("tool_call_id", 1, true) and body:find("report_observations", 1, true) then
        roundtrip = true
      end
      H.ok(not body:find(SECRET_MARKER, 1, true), "no outbound body carries the excluded secret")
    end
    H.ok(digest_seen, "the change digest (diff content) reached the model")
    H.ok(roundtrip, "report_observations completed a real tool roundtrip")
  end)

  H.test("activation binds to the live endpoint and survives a simulated restart", function()
    configure("activate")
    local proj = fixture("activate")
    H.ok(observer.enable(proj), "enable succeeds against the configured endpoint")
    local pid = records.projects.get(proj.identity).id
    local state_row = records.observer.state(pid)
    H.eq(state_row.enabled, 1, "activation persisted")
    H.eq(state_row.endpoint, endpoint, "endpoint recorded with the activation")

    -- Same data dir, fresh in-instance state: activation must carry over.
    observer._reset()
    mentor.shutdown()
    storage.close()
    agent.provider = nil
    mentor.setup({
      dev = { fake_provider = false },
      data_dir = require("mentor.config").get().data_dir,
      providers = {
        default = {
          endpoint = endpoint,
          model = model,
          api_key_env = "",
          timeout_s = 300,
          max_tokens = 8192,
          capabilities = { tools = true, streaming = true },
        },
      },
    })
    local st = observer._internals.state_for(proj)
    H.eq(st.enabled, true, "activation survives the restart at the same endpoint")
    H.ok(observer.disable(proj), "disable works and persists")
    H.eq(records.observer.state(pid).enabled, 0, "disable persisted")
  end)
end
