-- Integration: persistent memory and user control. Covers entry lifecycle
-- (create/update/history/revert), optimistic-concurrency conflicts including
-- simulated second instances, protection and user precedence, deletion
-- tombstones and recreation suppression, erasure with content-free audit,
-- global/project isolation, provenance rechecks that withhold newly excluded
-- entries, secret sanitization on write, and the atomic view-edit path.
-- No network.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local mentor = require("mentor")
local storage = require("mentor.storage")
local records = require("mentor.storage.records")
local memory = require("mentor.memory")

return function()
  ---Isolated storage + fixture project; returns the project table.
  local function configure(label, extra_config)
    mentor.shutdown()
    storage.close()
    local opts = { data_dir = fs.tmpdir() .. "/data-mem-" .. label }
    for k, v in pairs(extra_config or {}) do
      opts[k] = v
    end
    mentor.setup(opts)
    local dir = fs.tmpdir() .. "/mem-" .. label
    vim.fn.mkdir(dir, "p")
    return { identity = dir, root = dir, is_git = false, git_common_dir = nil }
  end

  H.test("remember stores an entry with history and sane defaults", function()
    configure("create")
    local res = memory.remember({
      scope = "project",
      project = nil, -- filled by caller? no: project scope needs project
    })
    H.ok(not res.ok, "project scope without project context fails clearly")

    local proj = configure("create2")
    res = memory.remember({
      scope = "project",
      project = proj,
      summary = "We chose SQLite over a flat file",
      content = "Chosen for transactional integrity.",
      category = "decision",
      refs = { "docs/adr.md" },
      author = "agent",
    })
    H.ok(res.ok, "created")
    H.eq(res.entry.revision, 1, "first revision")
    H.eq(res.entry.uncertainty, "hypothesis", "agent writes default to hypothesis")
    H.ok(not res.entry.protected, "agent entries start unprotected")
    local revs = records.memory.list_revisions(res.entry.id)
    H.eq(#revs, 1, "creation snapshot exists")
    H.eq(revs[1].reason, "created", "reason recorded")
  end)

  H.test("updates bump revisions and record history; stale writes are rejected", function()
    local proj = configure("update")
    local created = memory.remember({
      scope = "project",
      project = proj,
      summary = "Prefers hints over solutions",
      category = "preference",
      author = "agent",
    })
    local id = created.entry.id

    local upd =
      memory.update(id, "agent", 1, { content = "Confirmed by the developer." }, "developer confirmed")
    H.ok(upd.ok, "update at current revision")
    H.eq(upd.entry.revision, 2, "revision bumped")

    local stale = memory.update(id, "agent", 1, { content = "conflicting write" })
    H.ok(not stale.ok, "stale write rejected")
    H.contains_text(stale.error, "revision", "conflict message names the revision")

    -- A second Neovim instance modelled by a direct repository write (the
    -- same call path that instance's memory module would take).
    records.memory.update(id, 2, {
      category = "preference",
      summary = "Prefers hints over solutions",
      content = "other instance",
      uncertainty = "established",
      refs = nil,
    }, "user", "edited elsewhere")
    records.memory.append_revision(id, 3, {
      category = "preference",
      summary = "Prefers hints over solutions",
      content = "other instance",
      uncertainty = "established",
      refs = nil,
    }, "user", "edited elsewhere")
    local raced = memory.update(id, "agent", 2, { content = "our write" })
    H.ok(not raced.ok, "cross-instance conflict rejected")
    H.contains_text(raced.error, "re-read", "conflict message tells the writer to re-read")

    local revs = records.memory.list_revisions(id)
    H.eq(#revs, 3, "every change has a snapshot")
  end)

  H.test("revert re-applies an older snapshot as a new revision", function()
    local proj = configure("revert")
    local created = memory.remember({
      scope = "project",
      project = proj,
      summary = "Original decision",
      content = "v1 text",
      author = "agent",
    })
    memory.update(created.entry.id, "agent", 1, { content = "v2 text" })
    local back = memory.revert(created.entry.id, 1, "user")
    H.ok(back.ok, "reverted")
    H.eq(back.entry.content, "v1 text", "old content restored")
    H.eq(back.entry.revision, 3, "revert is a new revision")
    H.ok(back.entry.protected, "user reverts are protected")
  end)

  H.test("user-protected entries refuse agent changes until released", function()
    local proj = configure("protect")
    local created = memory.remember({
      scope = "project",
      project = proj,
      summary = "User's own correction",
      author = "user",
    })
    H.ok(created.entry.protected, "user writes are protected")

    local upd = memory.update(created.entry.id, "agent", 1, { content = "agent overwrite attempt" })
    H.ok(not upd.ok, "agent update refused")
    H.contains_text(upd.error, "protected", "message explains precedence")
    local del = memory.delete_entry(created.entry.id, "agent", 1)
    H.ok(not del.ok, "agent delete refused")

    memory.set_protected(created.entry.id, false)
    local upd2 = memory.update(created.entry.id, "agent", 1, { content = "now allowed" }, "with evidence")
    H.ok(upd2.ok, "released protection allows the update")
    local audit =
      storage.query("SELECT action FROM memory_audit WHERE entry_id = ? ORDER BY id;", { created.entry.id })
    H.eq(#audit, 1, "protection changes are audited")
    H.eq(audit[1].action, "unprotected", "audit history inspectable")
  end)

  H.test("user edits always take precedence over agent writes", function()
    local proj = configure("precedence")
    local created = memory.remember({
      scope = "project",
      project = proj,
      summary = "Agent note",
      content = "agent text",
      author = "agent",
    })
    local user_edit =
      memory.update(created.entry.id, "user", 1, { content = "user text" }, "edited in the memory view")
    H.ok(user_edit.ok, "user edit accepted")
    H.ok(user_edit.entry.protected, "user edit protects the entry")
    local agent_retry = memory.update(created.entry.id, "agent", 1, { content = "agent again" })
    H.ok(not agent_retry.ok, "agent cannot silently re-overwrite the user")
  end)

  H.test("deletion is reversible and suppresses automatic recreation", function()
    local proj = configure("tombstone")
    local created = memory.remember({
      scope = "project",
      project = proj,
      summary = "Temporary note about retries",
      author = "agent",
    })
    local del = memory.delete_entry(created.entry.id, "user", 1)
    H.ok(del.ok, "deleted")
    H.eq(del.entry.status, "deleted", "tombstone kept")

    local again = memory.remember({
      scope = "project",
      project = proj,
      summary = "Temporary note about retries", -- same derived key
      author = "agent",
    })
    H.ok(not again.ok, "agent recreation suppressed")
    H.contains_text(again.error, "deleted by the user", "suppression message explains")

    local restored = memory.restore(created.entry.id, "user", del.entry.revision)
    H.ok(restored.ok, "restore works")
    H.eq(restored.entry.status, "active", "active again")

    -- User-initiated recreation with the same key is allowed.
    memory.delete_entry(created.entry.id, "user", nil)
    local by_user = memory.remember({
      scope = "project",
      project = proj,
      summary = "Temporary note about retries",
      author = "user",
    })
    H.ok(by_user.ok, "user may recreate")
  end)

  H.test("erasure removes entry and history, keeping only a content-free marker", function()
    local proj = configure("erase")
    local created = memory.remember({
      scope = "project",
      project = proj,
      summary = "Entry to erase",
      content = "sensitive reasoning",
      author = "agent",
    })
    memory.update(created.entry.id, "agent", 1, { content = "more reasoning" })
    local res = memory.erase(created.entry.id)
    H.ok(res.ok, "erased")
    H.ok(memory.get(created.entry.id) == nil, "entry gone")
    H.eq(#records.memory.list_revisions(created.entry.id), 0, "history gone")
    local audit = storage.query("SELECT * FROM memory_audit WHERE entry_id = ?;", { created.entry.id })
    H.eq(#audit, 1, "content-free marker kept")
    H.eq(audit[1].action, "erased", "marker action")
    local has_content = false
    for _, v in pairs(audit[1]) do
      if type(v) == "string" and v:find("reasoning") then
        has_content = true
      end
    end
    H.ok(not has_content, "no content survives erasure")
  end)

  H.test("detected secrets never enter memory storage", function()
    local proj = configure("secrets")
    local res = memory.remember({
      scope = "project",
      project = proj,
      summary = "API credentials reminder",
      content = "Rotate the key AKIAIOSFODNN7EXAMPLE when done.",
      author = "agent",
    })
    H.ok(res.ok, "entry created")
    H.ok(res.redacted and res.redacted > 0, "redaction reported")
    H.contains_text(res.entry.content, "[REDACTED", "stored content is redacted")
    H.ok(not res.entry.content:find("AKIAIOSFODNN7EXAMPLE", 1, true), "secret not persisted")
  end)

  H.test("project memory never leaks to other projects; global is shared", function()
    -- One database, two projects: the isolation guarantee (two worktrees and
    -- nested repos already resolve to distinct identities elsewhere).
    local dir_a = fs.tmpdir() .. "/mem-iso-a"
    vim.fn.mkdir(dir_a, "p")
    local dir_b = fs.tmpdir() .. "/mem-iso-b"
    vim.fn.mkdir(dir_b, "p")
    mentor.shutdown()
    storage.close()
    mentor.setup({ data_dir = fs.tmpdir() .. "/data-mem-iso" })
    local proj_a = { identity = dir_a, root = dir_a, is_git = false, git_common_dir = nil }
    local proj_b = { identity = dir_b, root = dir_b, is_git = false, git_common_dir = nil }

    memory.remember({
      scope = "project",
      project = proj_a,
      summary = "A's architecture note",
      author = "agent",
    })
    memory.remember({ scope = "global", summary = "Developer prefers concise answers", author = "agent" })

    local visible_a, visible_b = memory.visible(proj_a), memory.visible(proj_b)
    H.eq(#visible_a, 2, "A sees its own plus global")
    H.eq(#visible_b, 1, "B sees only global")
    H.contains_text(visible_b[1].summary, "concise", "global entry shared")

    local listed = memory.list("all", proj_b, "active")
    H.eq(#listed, 1, "list horizon respects project scoping")
  end)

  H.test("recall withholds entries whose path provenance became excluded", function()
    local proj = configure("provenance")
    memory.remember({
      scope = "project",
      project = proj,
      summary = "Token rotation notes",
      content = "details learned from the operations file",
      refs = { "ops/rotation.md" },
      author = "agent",
    })
    memory.remember({
      scope = "project",
      project = proj,
      summary = "Prefers explicit tests",
      refs = { "testing philosophy" }, -- concept ref, never path-authorized
      author = "agent",
    })

    H.eq(#memory.recall(proj), 2, "both visible initially")
    mentor.setup({
      data_dir = require("mentor.config").get().data_dir,
      context = { exclusions = { "ops" } },
    })
    local recalled = memory.recall(proj)
    H.eq(#recalled, 1, "path-sourced entry withheld after tightening")
    H.contains_text(recalled[1].summary, "explicit tests", "concept-only entry unaffected")
  end)

  H.test("serialized memory tool results are re-authorized before replay", function()
    local proj = configure("replay")
    mentor.setup({
      data_dir = require("mentor.config").get().data_dir,
      context = { exclusions = { "ops" } },
    })
    local serialized = vim.json.encode({
      ok = true,
      entries = {
        {
          id = 1,
          revision = 1,
          scope = "project",
          category = "note",
          summary = "Token rotation notes",
          content = "secret-adjacent detail",
          uncertainty = "established",
          refs = { "ops/rotation.md" },
        },
        {
          id = 2,
          revision = 1,
          scope = "project",
          category = "note",
          summary = "Safe detail",
          content = "unaffected",
          uncertainty = "established",
          refs = { "src/main.c" },
        },
      },
    })
    local rewritten, changed = memory.reauthorize_result(serialized, proj)
    H.ok(changed, "rewritten")
    local decoded = vim.json.decode(rewritten)
    H.contains_text(decoded.entries[1].summary, "withheld", "excluded entry neutralized")
    H.ok(
      not rewritten:find("secret-adjacent detail", 1, true),
      "excluded content does not survive re-authorization"
    )
    H.eq(decoded.entries[2].content, "unaffected", "authorized entry untouched")
    -- Re-running is idempotent.
    local again, again_changed = memory.reauthorize_result(rewritten, proj)
    H.ok(not again_changed, "idempotent")
    H.eq(again, rewritten, "stable output")
  end)

  H.test("render_context injects a bounded memory block", function()
    local proj = configure("render")
    for i = 1, 20 do
      memory.remember({
        scope = "project",
        project = proj,
        summary = string.format("Learning objective %02d: ", i) .. string.rep("x", 120),
        content = string.rep("y", 300),
        author = "agent",
      })
    end
    local block = memory.render_context(proj)
    H.contains_text(block, "Persistent memory", "header present")
    H.contains_text(block, "request budget", "cap enforced")
    H.ok(#block <= require("mentor.config").get().memory.recall_max_bytes + 200, "block stays bounded")
  end)

  H.test("view edits commit atomically; a conflict rolls the whole batch back", function()
    local proj = configure("view")
    local one = memory.remember({
      scope = "project",
      project = proj,
      summary = "First entry",
      content = "v1",
      author = "agent",
    })
    local two = memory.remember({
      scope = "project",
      project = proj,
      summary = "Second entry",
      author = "agent",
    })

    -- A stale expected revision poisons the batch: nothing changes.
    records.memory.update(two.entry.id, 1, {
      category = "note",
      summary = "Second entry",
      content = "changed elsewhere",
      uncertainty = "hypothesis",
      refs = nil,
    }, "user", nil)
    local batch = memory.apply_view_edits(proj, {
      updates = {
        { id = one.entry.id, expected_revision = 1, summary = "First entry", content = "edited v2" },
        { id = two.entry.id, expected_revision = 1, summary = "Second entry", content = "our edit" },
      },
      creates = { { scope = "project", summary = "Brand new entry" } },
      deletes = {},
    })
    H.ok(not batch.ok, "batch rejected")
    H.ok(#batch.problems >= 1, "problems reported")
    H.eq(memory.get(one.entry.id).content, "v1", "update rolled back")
    H.eq(memory.get(one.entry.id).revision, 1, "revision untouched")
    H.eq(#memory.visible(proj), 2, "create rolled back too")

    -- Fresh revisions: the batch now commits.
    local fresh = memory.get(two.entry.id)
    local ok_batch = memory.apply_view_edits(proj, {
      updates = {
        { id = one.entry.id, expected_revision = 1, summary = "First entry", content = "edited v2" },
        {
          id = two.entry.id,
          expected_revision = fresh.revision,
          summary = "Second entry",
          content = "our edit",
        },
      },
      creates = { { scope = "project", summary = "Brand new entry" } },
      deletes = { two.entry.id },
    })
    H.ok(ok_batch.ok, "batch committed")
    H.eq(memory.get(one.entry.id).content, "edited v2", "update applied")
    H.eq(memory.get(one.entry.id).protected, true, "view edits protect")
    H.eq(memory.get(two.entry.id).status, "deleted", "block removed in view = deleted")
    local found = false
    for _, e in ipairs(memory.visible(proj)) do
      if e.summary == "Brand new entry" then
        found = true
        H.ok(e.protected, "created via view is user-protected")
        H.eq(e.uncertainty, "hypothesis", "default uncertainty")
      end
    end
    H.ok(found, "creation committed")
  end)

  H.test("counts summarize memory state for the status view", function()
    local proj = configure("counts")
    memory.remember({ scope = "global", summary = "Global thing", author = "agent" })
    local p1 =
      memory.remember({ scope = "project", project = proj, summary = "Project thing", author = "user" })
    local p2 =
      memory.remember({ scope = "project", project = proj, summary = "Will delete", author = "agent" })
    memory.delete_entry(p2.entry.id, "user", nil)
    local c = memory.counts(proj)
    H.eq(c.global, 1, "global count")
    H.eq(c.project, 1, "project count")
    H.eq(c.protected, 1, "protected count")
    H.eq(c.deleted, 1, "tombstone count")
    H.ok(p1.entry.protected, "user entry protected in counts")
  end)
end
