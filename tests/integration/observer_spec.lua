-- Integration: the Observer engine with the scripted fake provider —
-- activation rules (off until explicitly enabled, bound to the endpoint,
-- disabled again on endpoint change), trigger scheduling seams (idle,
-- coalescing, pause), the publication pipeline (dedup, dismissal
-- cooldown, staleness when sources move mid-pass, cancellation generations
-- dropping late results), the notification policy (category rules and
-- silence), background request caps shared across instances, daily
-- consolidation scheduling, and the change digest (diffs, unsaved buffers,
-- policy-hidden files). No network.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local mentor = require("mentor")
local project = require("mentor.project")
local observer = require("mentor.observer")
local records = require("mentor.storage.records")
local storage = require("mentor.storage")
local fake = require("mentor.provider.fake")
local chat = require("mentor.ui.chat")
local consolidate = require("mentor.memory.consolidate")

return function()
  ---Isolated environment with a fixture git repo; returns the project.
  local function configure(label, extra_config)
    chat.reset()
    observer._reset()
    project.reset()
    mentor.shutdown()
    storage.close()
    fake._scripted = nil
    fake.chunk_delay_ms = 1
    vim.cmd("silent! only")
    local opts = {
      dev = { fake_provider = true },
      data_dir = fs.tmpdir() .. "/data-obs-" .. label,
      providers = { observer = { endpoint = "http://127.0.0.1:1/v1", model = "observer-model" } },
      observer = {
        edit_idle_ms = 30,
        save_debounce_ms = 20,
        notify_min_gap_ms = 0,
      },
    }
    for k, v in pairs(extra_config or {}) do
      opts[k] = v
    end
    mentor.setup(opts)
    local dir = fs.git_repo(fs.tmpdir() .. "/obs-" .. label)
    fs.write(dir .. "/main.lua", "local function handle(value)\n  return value + 1\nend\n")
    return project.for_dir(dir)
  end

  local function focus(proj, rel)
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/" .. (rel or "main.lua")))
  end

  local function pid_of(proj)
    local row = records.projects.get(proj.identity)
    return row and row.id
  end

  local function find_by_digest(pid, digest)
    for _, row in ipairs(records.observations.list_active(pid)) do
      if row.issue_digest == digest then
        return row
      end
    end
    return nil
  end

  local function wait_for(pred, ms)
    H.ok(vim.wait(ms or 5000, pred, 5), "condition not met within " .. tostring(ms or 5000) .. "ms")
  end

  local function settled()
    return observer._internals.is_running() == nil
  end

  ---One scripted pass: a report_observations call, then a final message.
  local function script_pass(findings, final_text)
    fake.script({
      {
        content = "reviewing the change",
        tool_calls = { { name = "report_observations", arguments = { findings = findings } } },
      },
      { content = final_text or "done" },
    })
  end

  local function finding(over)
    return {
      category = over.category or "correctness",
      summary = over.summary or "Call sites were not updated",
      reasoning = over.reasoning or "handle() gained a parameter but one caller still passes one argument",
      certainty = over.certainty or "high",
      refs = over.refs or { "main.lua" },
      question = over.question,
      issue_key = over.issue_key,
    }
  end

  -- ---------------------------------------------------------------------
  -- Activation

  H.test("observation stays off until explicitly enabled; no requests without it", function()
    local proj = configure("off")
    focus(proj)
    H.eq(observer.status_snapshot(proj).enabled, false, "disabled by default")

    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    observer._trigger(vim.api.nvim_win_get_buf(0), "save")
    vim.wait(120)
    H.ok(settled(), "no background pass started")
    H.eq(records.observations.count(pid_of(proj)), 0, "no findings")
    H.ok(vim.uv.now() > 0, "sanity")

    local ok = observer.enable(proj)
    H.ok(ok, "enable succeeds once a provider is configured")
    local state_row = records.observer.state(pid_of(proj))
    H.eq(state_row.enabled, 1, "activation persisted")
    H.eq(state_row.endpoint, "http://127.0.0.1:1/v1", "endpoint recorded with the activation")
  end)

  H.test("enabling refuses when the Observer endpoint is not configured", function()
    local proj = configure("noendpoint", { providers = { observer = { endpoint = "", model = "" } } })
    focus(proj)
    local ok, err = observer.enable(proj)
    H.ok(not ok, "enable refused")
    H.contains_text(err, "endpoint", "actionable message")
    H.eq(observer.status_snapshot(proj).enabled, false, "still disabled")
  end)

  H.test("activation persists per endpoint; changing the endpoint disables and persists off", function()
    local proj = configure("endpoint")
    focus(proj)
    H.ok(observer.enable(proj), "enabled")

    -- A later instance sees a different Observer endpoint.
    observer._reset()
    mentor.setup({
      dev = { fake_provider = true },
      data_dir = require("mentor.config").get().data_dir,
      providers = { observer = { endpoint = "http://127.0.0.1:2/v1", model = "observer-model" } },
    })
    local st = observer._internals.state_for(proj)
    H.eq(st.enabled, false, "endpoint change forces re-activation")
    H.eq(records.observer.state(pid_of(proj)).enabled, 0, "persisted disabled")
  end)

  -- ---------------------------------------------------------------------
  -- Triggers and scheduling

  H.test("idle trigger runs a pass and publishes findings under the notification policy", function()
    local proj = configure("publish")
    focus(proj)
    H.ok(observer.enable(proj), "enabled")
    script_pass({
      finding({ issue_key = "nil-guard-main" }),
      finding({ category = "praise", summary = "clean signature change", issue_key = "praise-1" }),
      finding({
        category = "design",
        certainty = "low",
        summary = "consider a seam",
        issue_key = "seam-idea",
      }),
      finding({ category = "learning", summary = "related to earlier discussion", issue_key = "learn-1" }),
    })

    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return settled() and records.observations.count(pid_of(proj)) == 4
    end)

    local pid = pid_of(proj)
    local concrete = find_by_digest(pid, "nil-guard-main")
    H.ok(concrete, "concrete finding persisted with its dedup key")
    H.ok(concrete.notified_at ~= nil, "correctness finding notified")
    local praise = find_by_digest(pid, "praise-1")
    H.ok(praise and praise.notified_at == nil, "praise never interrupts")
    local design = find_by_digest(pid, "seam-idea")
    H.ok(
      design and design.certainty == "low" and design.notified_at == nil,
      "low-certainty design stays quiet"
    )
    local learning = find_by_digest(pid, "learn-1")
    H.ok(learning and learning.notified_at == nil, "learning findings are silent by default")
    for _, row in ipairs(records.observations.list_active(pid)) do
      H.eq(row.stale, 0, "fresh findings are not stale")
      H.ok(row.refs ~= nil and row.refs:find("main%.lua") ~= nil, "refs persisted")
    end
  end)

  H.test("an explicit empty findings list is a valid no-result", function()
    local proj = configure("empty")
    focus(proj)
    H.ok(observer.enable(proj), "enabled")
    script_pass({}, "nothing cleared the bar")
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return settled() and #fake._scripted == 0
    end)
    H.eq(records.observations.count(pid_of(proj)), 0, "nothing persisted")
  end)

  H.test("repeated triggers while a pass runs coalesce into one newer pass", function()
    local proj = configure("coalesce")
    focus(proj)
    fake.chunk_delay_ms = 25
    H.ok(observer.enable(proj), "enabled")
    script_pass({ finding({ issue_key = "issue-a" }) }, "first pass done")
    fake._scripted[#fake._scripted + 1] = {
      content = "second look",
      tool_calls = {
        { name = "report_observations", arguments = { findings = { finding({ issue_key = "issue-b" }) } } },
      },
    }
    fake._scripted[#fake._scripted + 1] = { content = "second pass done" }

    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return not settled()
    end)
    -- More edits during the run: one pending slot, newest state wins.
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    H.ok(observer.status_snapshot(proj).pending, "pending slot set")
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")

    wait_for(function()
      return settled() and records.observations.count(pid_of(proj)) == 2
    end)
    H.eq(observer.status_snapshot(proj).pending, false, "pending consumed")
    local pid = pid_of(proj)
    H.ok(find_by_digest(pid, "issue-a"), "first pass published")
    H.ok(find_by_digest(pid, "issue-b"), "coalesced pass published")
  end)

  H.test("pause suspends automatic passes for the session; resume restores them", function()
    local proj = configure("pause")
    focus(proj)
    H.ok(observer.enable(proj), "enabled")
    H.ok(observer.pause(proj), "paused")
    script_pass({ finding({ issue_key = "never" }) })
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    vim.wait(150)
    H.ok(settled(), "no pass while paused")
    H.eq(#fake._scripted, 2, "no provider request while paused")
    H.eq(records.observations.count(pid_of(proj)), 0, "nothing published while paused")

    H.ok(observer.resume(proj), "resumed")
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return settled() and records.observations.count(pid_of(proj)) == 1
    end)
  end)

  H.test(":MentorStop cancels a running pass and its pending jobs", function()
    local proj = configure("stop")
    focus(proj)
    fake.chunk_delay_ms = 40
    H.ok(observer.enable(proj), "enabled")
    script_pass({ finding({ issue_key = "not-yet" }) })
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return not settled()
    end)
    vim.cmd("MentorStop")
    wait_for(settled)
    vim.wait(50)
    H.eq(records.observations.count(pid_of(proj)), 0, "cancelled pass publishes nothing")
  end)

  -- ---------------------------------------------------------------------
  -- Publication: dedup, staleness, cancellation generations

  H.test("duplicates of active findings drop; dismissed re-confirmations stay quiet", function()
    local proj = configure("dedup")
    focus(proj)
    H.ok(observer.enable(proj), "enabled")
    script_pass({ finding({ issue_key = "sig-mismatch" }) })
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return settled() and records.observations.count(pid_of(proj)) == 1
    end)
    local first = find_by_digest(pid_of(proj), "sig-mismatch")
    H.ok(first.notified_at ~= nil, "first pass notified")

    -- Same issue re-reported while still active: dropped entirely.
    script_pass({ finding({ issue_key = "sig-mismatch", summary = "call sites not updated (again)" }) })
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return settled() and #fake._scripted == 0
    end)
    local active_rows = records.observations.list_active(pid_of(proj))
    H.eq(#active_rows, 1, "duplicate of an active finding dropped")

    -- Dismiss, then the same issue is re-confirmed: kept, but silent
    -- (inside the ten-minute per-finding cooldown).
    records.observations.set_dismissed(first.id, true)
    script_pass({ finding({ issue_key = "sig-mismatch", summary = "still mismatched" }) })
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return settled() and records.observations.count(pid_of(proj)) == 1 and #fake._scripted == 0
    end)
    local reconfirmed = find_by_digest(pid_of(proj), "sig-mismatch")
    H.neq(reconfirmed.id, first.id, "re-confirmation persisted")
    H.ok(reconfirmed.notified_at == nil, "re-confirmed within cooldown does not interrupt")
  end)

  H.test("a source that moves mid-pass publishes marked stale and never notifies", function()
    local proj = configure("stale")
    local buf = (function()
      focus(proj)
      return vim.api.nvim_win_get_buf(0)
    end)()
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      { "local function handle(value)", "  return value + 2", "end" }
    )
    H.ok(observer.enable(proj), "enabled")
    fake.chunk_delay_ms = 25
    script_pass({ finding({ issue_key = "mid-edit" }) }, "done thinking")

    observer._trigger(buf, "edit")
    wait_for(function()
      return not settled()
    end)
    -- The developer keeps typing while the model works.
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      { "local function handle(value, opts)", "  return value + 2", "end" }
    )
    wait_for(function()
      return settled() and records.observations.count(pid_of(proj)) == 1
    end)
    local row = find_by_digest(pid_of(proj), "mid-edit")
    H.eq(row.stale, 1, "finding marked stale")
    H.ok(row.notified_at == nil, "stale finding never interrupts")
  end)

  H.test("preemption drops the in-flight pass before it can publish", function()
    local proj = configure("preempt")
    focus(proj)
    fake.chunk_delay_ms = 25
    H.ok(observer.enable(proj), "enabled")
    script_pass({ finding({ issue_key = "interrupted" }) }, "thinking for a while about this change")
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return not settled()
    end)
    local n = observer.preempt()
    H.eq(n, 1, "one background operation preempted")
    wait_for(settled)
    vim.wait(120) -- a late provider result must not resurrect the pass
    H.eq(records.observations.count(pid_of(proj)), 0, "late results never publish")
  end)

  H.test("restored findings start stale; reopening the list revalidates them", function()
    local proj = configure("restore")
    focus(proj)
    H.ok(observer.enable(proj), "enabled")
    script_pass({ finding({ issue_key = "persist-me" }) })
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return settled() and records.observations.count(pid_of(proj)) == 1
    end)
    local id = find_by_digest(pid_of(proj), "persist-me").id

    -- Simulated restart: everything carried over starts stale...
    observer._reset()
    observer._internals.state_for(proj)
    H.eq(records.observations.get(id).stale, 1, "restored finding starts stale")

    -- ...and fingerprint revalidation clears it when nothing has moved.
    observer.revalidate_findings(proj)
    H.eq(records.observations.get(id).stale, 0, "revalidated against current state")

    -- Moving the referenced file marks it stale again.
    fs.write(proj.root .. "/main.lua", "-- changed later\n")
    observer.revalidate_findings(proj)
    H.eq(records.observations.get(id).stale, 1, "moved source marked stale")
  end)

  -- ---------------------------------------------------------------------
  -- Explicit review, budgets, and consolidation scheduling

  H.test("explicit review runs without activation and publishes through the same pipeline", function()
    local proj = configure("review")
    focus(proj)
    H.eq(observer.status_snapshot(proj).enabled, false, "not enabled")
    script_pass({ finding({ issue_key = "reviewed-issue", category = "design", certainty = "medium" }) })
    local ok = observer.review(proj)
    H.ok(ok, "review accepted without activation")
    wait_for(function()
      return settled() and records.observations.count(pid_of(proj)) == 1
    end)
    local row = find_by_digest(pid_of(proj), "reviewed-issue")
    H.ok(row.notified_at ~= nil, "review findings may notify")
  end)

  H.test("background hourly request cap blocks a new pass for the project", function()
    local proj = configure("hourly", {
      limits = { background = { requests_per_hour_per_project = 1 } },
    })
    focus(proj)
    local agent = require("mentor.agent")
    local function run_background()
      local info, done = nil, false
      local handle = agent.run({
        mode = "observer",
        kind = "background",
        project = proj,
        messages = { { role = "system", content = "s" }, { role = "user", content = "u" } },
        tools = {},
        on_done = function(_, got)
          info, done = got, true
        end,
      })
      H.ok(handle, "run started")
      wait_for(function()
        return done
      end)
      return info
    end

    fake.script({ { content = "first" } })
    local first = run_background()
    H.eq(first.usage.model_requests, 1, "first pass used one request")

    local second = run_background() -- DEFAULT_REPLY would answer if dispatched
    H.contains_text(second.stop_reason or "", "hourly request cap", "second pass blocked")
    H.eq(second.usage.model_requests, 0, "no request reached the provider")
  end)

  H.test("background daily estimated-token cap blocks further passes for the project", function()
    local proj = configure("daily", {
      limits = {
        background = { requests_per_hour_per_project = 50, est_tokens_per_day_per_project = 1 },
      },
    })
    focus(proj)
    local agent = require("mentor.agent")
    fake.script({ { content = "uses some tokens along the way" } })
    local info, done = nil, false
    local handle = agent.run({
      mode = "observer",
      kind = "background",
      project = proj,
      messages = { { role = "system", content = "s" }, { role = "user", content = "u" } },
      tools = {},
      on_done = function(_, got)
        info, done = got, true
      end,
    })
    H.ok(handle, "run started")
    wait_for(function()
      return done
    end)
    H.eq(info.usage.model_requests, 1, "first request went through")

    info, done = nil, false
    handle = agent.run({
      mode = "observer",
      kind = "background",
      project = proj,
      messages = { { role = "system", content = "s" }, { role = "user", content = "u" } },
      tools = {},
      on_done = function(_, got)
        info, done = got, true
      end,
    })
    H.ok(handle, "second run started")
    wait_for(function()
      return done
    end)
    H.contains_text(info.stop_reason or "", "daily estimated token cap", "blocked by the daily cap")
    H.eq(info.usage.model_requests, 0, "nothing dispatched past the daily cap")
  end)

  H.test("consolidation is scheduled after a pass at most once per day", function()
    local proj = configure("consolidate")
    focus(proj)
    local pid = pid_of(proj)
    records.memory.insert({
      scope = "project",
      project_id = pid,
      entry_key = "boundary-one",
      category = "architecture",
      summary = "storage module boundary error handling",
      uncertainty = "established",
      author = "model",
    })
    records.memory.insert({
      scope = "project",
      project_id = pid,
      entry_key = "boundary-two",
      category = "architecture",
      summary = "storage module boundary error handling notes",
      uncertainty = "established",
      author = "model",
    })
    H.ok(observer.enable(proj), "enabled")

    -- Pass 1: report nothing; consolidation should then be scheduled.
    script_pass({}, "clean pass")
    fake._scripted[#fake._scripted + 1] = { content = "consolidation done" }
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return settled() and not consolidate.is_active() and #fake._scripted == 0
    end)
    H.eq(records.observer.consolidation_day(pid), records.usage.today(), "day marked")

    -- Same day: no second scheduled pass (script stays fully consumed by
    -- the observation itself).
    script_pass({}, "clean again")
    observer._trigger(vim.api.nvim_win_get_buf(0), "edit")
    wait_for(function()
      return settled() and #fake._scripted == 0
    end)
    H.ok(not consolidate.is_active(), "no consolidation on the same day")
  end)

  -- ---------------------------------------------------------------------
  -- Change digest

  H.test("digest carries diffs and unsaved buffer state, and hides policy-excluded files", function()
    local proj = configure("digest")
    fs.write(proj.root .. "/.env", "API_KEY=super-secret-value\n")
    fs.write(proj.root .. "/helper.lua", "return 1\n")
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/helper.lua"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "return 42" })
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/main.lua"))
    vim.api.nvim_buf_set_lines(
      0,
      0,
      -1,
      false,
      { "local function handle(value, opts)", "  return value + 1", "end" }
    )

    local digest, baseline = observer._internals.build_digest(proj)
    H.contains_text(digest, "main.lua", "changed file listed")
    H.contains_text(digest, "buffer (unsaved edits)", "unsaved buffer state wins over disk")
    H.contains_text(digest, "return 42", "second modified buffer included")
    H.contains_text(digest, "hidden by the access policy", "excluded files counted, not transmitted")
    H.ok(digest:find("API_KEY") == nil, "secret file content never enters the digest")
    H.ok(baseline.paths[proj.root .. "/main.lua"] ~= nil, "baseline fingerprint recorded for revalidation")
    H.ok(baseline.paths[proj.root .. "/.env"] == nil, "excluded file never fingerprinted")
  end)

  H.test("the reporting tool refuses outside an observation run and validates like every tool", function()
    local proj = configure("tool")
    focus(proj)
    local tools_mod = require("mentor.tools")
    local ctx = tools_mod.new_operation({ project = proj })
    local res = tools_mod.run(ctx, "report_observations", {
      findings = { finding({ issue_key = "x" }) },
    })
    H.eq(res.ok, false, "refused without a receiving run")
    H.contains_text(res.error or "", "no observation run", "actionable message")

    local schema = tools_mod.schemas({ "report_observations" })
    H.eq(#schema, 1, "schema offered")
    H.eq(schema[1]["function"].parameters.properties.findings.type, "array", "array parameter typed")
    H.eq(schema[1]["function"].parameters.properties.findings.items.type, "object", "object items")

    local bad = tools_mod.run(ctx, "report_observations", { findings = { "not-an-object" } })
    H.eq(bad.ok, false, "malformed findings refused")
  end)
end
