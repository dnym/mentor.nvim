-- Integration: the model-facing memory tools driven through the shared
-- agent loop, Coach's memory injection and replay-time provenance
-- rechecks, the explicit conversation-clearing path, and the bounded
-- consolidation pass. Scripted fake provider only; no network.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local mentor = require("mentor")
local project = require("mentor.project")
local agent = require("mentor.agent")
local fake = require("mentor.provider.fake")
local storage = require("mentor.storage")
local records = require("mentor.storage.records")
local memory = require("mentor.memory")
local chat = require("mentor.ui.chat")
local consolidate = require("mentor.memory.consolidate")

return function()
  ---Isolated environment with a fixture git repo; returns the project.
  local function configure(label, extra_config)
    chat.reset()
    project.reset()
    mentor.shutdown()
    storage.close()
    agent.provider = nil
    fake._scripted = nil
    fake.chunk_delay_ms = 1
    local opts = {
      dev = { fake_provider = true },
      data_dir = fs.tmpdir() .. "/data-mt-" .. label,
    }
    for k, v in pairs(extra_config or {}) do
      opts[k] = v
    end
    mentor.setup(opts)
    local dir = fs.git_repo(fs.tmpdir() .. "/mt-" .. label)
    fs.write(dir .. "/main.lua", "print('work in progress')\n")
    return project.for_dir(dir)
  end

  local function focus(proj)
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/main.lua"))
  end

  ---Runs one agent operation with scripted turns; waits for completion.
  local function run_operation(proj, turns, extra)
    fake.script(turns)
    local captured = { deltas = {}, messages = {}, tools = {} }
    local opts = {
      mode = "coach",
      project = proj,
      messages = {
        { role = "system", content = "test prompt" },
        { role = "user", content = "please remember this" },
      },
      on_delta = function(chunk)
        captured.deltas[#captured.deltas + 1] = chunk
      end,
      on_message = function(msg)
        captured.messages[#captured.messages + 1] = msg
      end,
      on_tool = function(phase, call, result)
        if phase == "done" then
          captured.tools[#captured.tools + 1] = { name = call.name, result = result }
        end
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
    local ok = vim.wait(5000, function()
      return captured.done ~= nil
    end, 5)
    H.ok(ok, "operation settled in time")
    return captured
  end

  ---Captures every message array dispatched to the provider this test.
  local function capture_dispatches()
    local dispatched = {}
    agent.provider = {
      chat = function(req)
        dispatched[#dispatched + 1] = req.messages
        return fake.chat(req)
      end,
    }
    return dispatched
  end

  H.test("memory_remember persists a sanitized entry through the agent loop", function()
    local proj = configure("remember")
    local captured = run_operation(proj, {
      {
        content = "",
        tool_calls = {
          {
            name = "memory_remember",
            arguments = {
              scope = "project",
              summary = "Prefers progressive hints over full solutions",
              content = "The ops notes leaked AKIAIOSFODNN7EXAMPLE once; rotate it.",
              category = "preference",
              refs = "main.lua",
            },
          },
        },
      },
      { content = "noted" },
    })
    H.eq(captured.done.err, nil, "no loop error")
    H.eq(captured.tools[1].name, "memory_remember", "tool ran")
    H.ok(captured.tools[1].result.ok, "remember succeeded")
    local entries = memory.visible(proj)
    H.eq(#entries, 1, "one stored entry")
    H.contains_text(entries[1].content, "[REDACTED", "stored content is redacted")
    H.ok(not entries[1].content:find("AKIAIOSFODNN7EXAMPLE", 1, true), "secret never reaches memory storage")
    H.eq(entries[1].uncertainty, "hypothesis", "agent writes default to hypothesis")
    H.eq(entries[1].refs, { "main.lua" }, "refs parsed from the tool argument")
  end)

  H.test("protected user entries refuse agent updates through the tools", function()
    local proj = configure("protected")
    local mine = memory.remember({
      scope = "project",
      project = proj,
      summary = "My own workflow rules",
      content = "the developer's wording",
      author = "user",
    })
    local captured = run_operation(proj, {
      {
        content = "",
        tool_calls = {
          {
            name = "memory_update",
            arguments = {
              entry_id = mine.entry.id,
              expected_revision = 1,
              content = "agent overwrite attempt",
            },
          },
          {
            name = "memory_delete",
            arguments = { entry_id = mine.entry.id, expected_revision = 1 },
          },
        },
      },
      { content = "understood, I will not touch it" },
    })
    H.eq(#captured.tools, 2, "both refusals ran")
    for _, t in ipairs(captured.tools) do
      H.ok(not t.result.ok, t.name .. " refused")
      H.contains_text(t.result.error, "protected", "refusal explains user precedence")
    end
    local entry = memory.get(mine.entry.id)
    H.eq(entry.content, "the developer's wording", "user text intact")
    H.eq(entry.status, "active", "entry not deleted")
  end)

  H.test("memory tool arguments are schema-validated like every tool", function()
    local proj = configure("schemas")
    local captured = run_operation(proj, {
      {
        content = "",
        tool_calls = {
          { name = "memory_remember", arguments = { scope = "project", extra = "nope" } },
          { name = "memory_update", arguments = { entry_id = 1 } },
        },
      },
      { content = "sorry" },
    })
    H.contains_text(captured.tools[1].result.error, "unknown parameter", "unknown parameter rejected")
    H.contains_text(
      captured.tools[1].result.error,
      "missing required parameter summary",
      "required parameters enforced"
    )
    H.contains_text(
      captured.tools[2].result.error,
      "missing required parameter",
      "integer call still validated"
    )
    H.eq(#memory.visible(proj), 0, "nothing persisted from invalid calls")
  end)

  H.test("stored memory results recheck provenance before retransmission", function()
    local proj = configure("replay-agent", { context = { exclusions = { "ops" } } })
    local serialized = vim.json.encode({
      ok = true,
      entries = {
        {
          id = 1,
          revision = 1,
          scope = "project",
          key = "token-rotation-notes",
          category = "note",
          summary = "Token rotation notes",
          content = "secret-adjacent detail",
          uncertainty = "established",
          refs = { "ops/rotation.md" },
          protected = false,
          status = "active",
          author = "agent",
        },
        {
          id = 2,
          revision = 1,
          scope = "project",
          key = "build-note",
          category = "note",
          summary = "Build note",
          content = "unaffected detail",
          uncertainty = "established",
          refs = { "main.lua" },
          protected = false,
          status = "active",
          author = "agent",
        },
      },
    })
    local dispatched = capture_dispatches()
    local captured = run_operation(proj, { { content = "understood" } }, {
      messages = {
        { role = "system", content = "test prompt" },
        {
          role = "assistant",
          content = "",
          tool_calls = {
            { id = "prior1", type = "function", ["function"] = { name = "memory_list", arguments = "{}" } },
          },
        },
        { role = "tool", tool_call_id = "prior1", content = serialized, tool = "memory_list" },
      },
    })
    H.eq(captured.done.err, nil, "operation completed")
    H.contains_text(vim.inspect(dispatched[1]), "withheld", "excluded entry neutralized in the request")
    H.ok(not vim.inspect(dispatched[1]):find("secret-adjacent", 1, true), "excluded content never dispatched")
    H.contains_text(vim.inspect(dispatched[1]), "unaffected detail", "authorized entry survives")
    agent.provider = nil
  end)

  H.test("Coach injects relevant memory into the request and can clear the transcript", function()
    local proj = configure("inject")
    focus(proj)
    memory.remember({
      scope = "project",
      project = proj,
      summary = "Explains with diagrams before code",
      author = "agent",
    })
    local dispatched = capture_dispatches()
    vim.cmd("MentorChat")
    chat.ask("hello")
    local ok = vim.wait(3000, function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end, 5)
    H.ok(ok, "chat request settled")
    H.ok(#dispatched >= 1, "request dispatched")
    H.contains_text(
      dispatched[1][1].content,
      "Persistent memory",
      "memory block appended to the system prompt"
    )
    H.contains_text(dispatched[1][1].content, "Explains with diagrams before code", "entry injected")
    agent.provider = nil

    local row_id = records.projects.touch({
      identity = proj.identity,
      root = proj.root,
      is_git = proj.is_git,
      git_common_dir = proj.git_common_dir,
    })
    H.ok(records.conversations.count(row_id, "coach") > 0, "transcript stored")

    -- Explicit clearing is independent of memory: chat rows go, entries stay.
    local removed = chat.clear(proj)
    H.ok(removed > 0, "clear reports removals")
    H.eq(records.conversations.count(row_id, "coach"), 0, "transcript gone")
    H.eq(#memory.visible(proj), 1, "memory untouched by chat clearing")
  end)

  H.test("Coach replay withholds persisted memory results that became excluded", function()
    local proj = configure("chat-replay")
    focus(proj)
    local row_id = records.projects.touch({
      identity = proj.identity,
      root = proj.root,
      is_git = proj.is_git,
      git_common_dir = proj.git_common_dir,
    })
    records.conversations.append(row_id, "coach", { role = "user", content = "what do you remember?" })
    records.conversations.append(row_id, "coach", {
      role = "assistant",
      content = "checking memory",
      tool_calls = {
        { id = "c1", type = "function", ["function"] = { name = "memory_list", arguments = "{}" } },
      },
    })
    records.conversations.append(row_id, "coach", {
      role = "tool",
      tool_call_id = "c1",
      tool = "memory_list",
      content = vim.json.encode({
        ok = true,
        entries = {
          {
            id = 9,
            revision = 1,
            scope = "project",
            key = "rotation",
            category = "note",
            summary = "Rotation details",
            content = "secret-adjacent detail",
            uncertainty = "established",
            refs = { "ops/rotation.md" },
            protected = false,
            status = "active",
            author = "agent",
          },
        },
      }),
    })

    -- Same environment, tightened policy: the excluded path is now off-limits.
    mentor.setup({
      dev = { fake_provider = true },
      data_dir = fs.tmpdir() .. "/data-mt-chat-replay",
      context = { exclusions = { "ops" } },
    })
    local dispatched = capture_dispatches()
    vim.cmd("MentorChat")
    chat.ask("and now?")
    local ok = vim.wait(3000, function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end, 5)
    H.ok(ok, "chat request settled")
    local payload = vim.inspect(dispatched[#dispatched])
    H.contains_text(payload, "withheld", "persisted memory result re-authorized on replay")
    H.ok(not payload:find("secret-adjacent", 1, true), "excluded memory content never retransmitted")
    agent.provider = nil
  end)

  H.test("consolidation merges duplicates and never touches protected entries", function()
    local proj = configure("consolidate")
    local a = memory.remember({
      scope = "project",
      project = proj,
      summary = "Table-driven tests catch parser edge cases",
      content = "noted during review",
      category = "convention",
      refs = { "tests/" },
      author = "agent",
    })
    local b = memory.remember({
      scope = "project",
      project = proj,
      summary = "Table-driven tests catch parser regressions too",
      content = "stated by the developer",
      category = "convention",
      author = "agent",
    })
    local mine = memory.remember({
      scope = "project",
      project = proj,
      summary = "Table-driven tests catch parser edge cases in this repo",
      content = "developer's own note",
      category = "convention",
      author = "user",
    })
    local other = memory.remember({
      scope = "project",
      project = proj,
      summary = "Storage choice",
      category = "decision",
      author = "agent",
    })

    fake.script({
      {
        content = "",
        tool_calls = {
          {
            name = "memory_update",
            arguments = {
              entry_id = b.entry.id,
              expected_revision = 1,
              content = "Consolidated rule: table-driven tests cover parser edge cases and regressions.",
              reason = "merged two duplicate convention notes",
            },
          },
        },
      },
      {
        content = "",
        tool_calls = {
          {
            name = "memory_delete",
            arguments = {
              entry_id = a.entry.id,
              expected_revision = 1,
              reason = "merged into the other convention note",
            },
          },
        },
      },
      { content = "Merged the duplicate convention notes." },
    })
    local done
    local handle = consolidate.run(proj, {
      on_done = function(err, info)
        done = { err = err, info = info }
      end,
    })
    H.ok(handle, "consolidation started")
    local settled = vim.wait(5000, function()
      return done ~= nil
    end, 5)
    H.ok(settled, "consolidation settled in time")
    H.eq(done.err, nil, "no error")
    H.eq(consolidate.active_count(), 0, "job finished")

    H.contains_text(memory.get(b.entry.id).content, "Consolidated rule", "merge applied")
    H.eq(memory.get(a.entry.id).status, "deleted", "merged-away entry tombstoned")
    local untouched = memory.get(mine.entry.id)
    H.eq(untouched.content, "developer's own note", "protected entry unchanged")
    H.eq(untouched.revision, 1, "protected entry never rewritten")
    H.eq(memory.get(other.entry.id).category, "decision", "unrelated entry unchanged")
  end)

  H.test("consolidation reports politely when nothing looks redundant", function()
    local proj = configure("consolidate-none")
    memory.remember({
      scope = "project",
      project = proj,
      summary = "Storage choice",
      category = "decision",
      author = "agent",
    })
    local handle, err = consolidate.run(proj, {})
    H.eq(handle, nil, "nothing to run")
    H.contains_text(err, "no redundant memory entries", "actionable message")
  end)
end
