-- Integration: conversation persistence and usage accounting through the
-- scoped repositories. Runs against the bundled migrations; no network.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local config = require("mentor.config")
local storage = require("mentor.storage")
local records = require("mentor.storage.records")

return function()
  local function project_id(label)
    storage.close()
    config.load({ data_dir = fs.tmpdir() .. "/data-conv-" .. label })
    return records.projects.touch({
      identity = "/repo/conv-" .. label,
      root = "/repo/conv-" .. label,
      is_git = false,
      git_common_dir = nil,
    })
  end

  H.test("conversations append and load linearly with tool metadata", function()
    local id = project_id("linear")
    records.conversations.append(id, "coach", { role = "user", content = "why does this fail?" })
    records.conversations.append(id, "coach", {
      role = "assistant",
      content = "let me look",
      tool_calls = { { id = "c1", name = "read_file", arguments = { path = "a.c" } } },
    })
    records.conversations.append(id, "coach", {
      role = "tool",
      content = '{"ok":true}',
      tool_call_id = "c1",
      source = "a.c",
    })

    local rows = records.conversations.load(id, "coach")
    H.eq(#rows, 3, "three rows")
    H.eq(rows[1].role, "user", "order preserved")
    local calls = vim.json.decode(rows[2].tool_calls)
    H.eq(calls[1].name, "read_file", "tool calls round-trip")
    H.eq(calls[1].arguments.path, "a.c", "tool arguments round-trip")
    H.eq(rows[3].tool_call_id, "c1", "tool answer linkage")
    H.eq(rows[3].source, "a.c", "provenance preserved")
    H.eq(records.conversations.count(id, "coach"), 3, "count")
  end)

  H.test("load with a limit keeps the newest turns oldest-first", function()
    local id = project_id("limit")
    for i = 1, 5 do
      records.conversations.append(id, "coach", { role = "user", content = "q" .. i })
    end
    local rows = records.conversations.load(id, "coach", 2)
    H.eq(#rows, 2, "limited")
    H.eq(rows[1].content, "q4", "oldest first")
    H.eq(rows[2].content, "q5", "newest last")
  end)

  H.test("conversations are scoped per project and mode", function()
    -- Two projects inside one database: scoping must separate both.
    storage.close()
    config.load({ data_dir = fs.tmpdir() .. "/data-conv-scope" })
    local id_a = records.projects.touch({
      identity = "/repo/conv-scope-a",
      root = "/repo/conv-scope-a",
      is_git = false,
      git_common_dir = nil,
    })
    local id_b = records.projects.touch({
      identity = "/repo/conv-scope-b",
      root = "/repo/conv-scope-b",
      is_git = false,
      git_common_dir = nil,
    })
    records.conversations.append(id_a, "coach", { role = "user", content = "in a" })
    records.conversations.append(id_b, "implement", { role = "user", content = "in b" })
    H.eq(#records.conversations.load(id_a, "coach"), 1, "a has its row")
    H.eq(#records.conversations.load(id_a, "implement"), 0, "a has no implement rows")
    H.eq(records.conversations.load(id_b, "implement")[1].content, "in b", "b scoped")
  end)

  H.test("reserved usage becomes daily totals with reported numbers", function()
    local id = project_id("usage-commit")
    local day = records.usage.today()
    local r = records.usage.reserve(id, day, "interactive", 1, 500)
    records.usage.mark_dispatched(r)
    records.usage.commit_actual(r, 700, 420, 280)
    local totals = records.usage.totals(id, day, "interactive")
    H.eq(totals.model_requests, 1, "one request")
    H.eq(totals.est_tokens, 700, "actual estimate folded in")
    H.eq(totals.reported_input, 420, "reported input")
    H.eq(totals.reported_output, 280, "reported output")
    H.eq(totals.open_reservations, 0, "nothing open")
  end)

  H.test("never-dispatched reservations release; dispatched ones never do", function()
    local id = project_id("usage-release")
    local day = records.usage.today()
    local pending = records.usage.reserve(id, day, "interactive", 1, 100)
    local spent = records.usage.reserve(id, day, "interactive", 1, 200)
    records.usage.mark_dispatched(spent)

    H.ok(records.usage.release(pending), "pending releases")
    H.ok(not records.usage.release(spent), "dispatched refuses release")
    local totals = records.usage.totals(id, day, "interactive")
    H.eq(totals.model_requests, 1, "only the dispatched one counts")
    H.eq(totals.est_tokens, 200, "reserved estimate held open")
    H.eq(totals.open_reservations, 1, "still open")
  end)

  H.test("startup sweep expires pending and conservatively retains stale dispatched", function()
    local id = project_id("usage-sweep")
    local day = records.usage.today()
    local never = records.usage.reserve(id, day, "interactive", 1, 100)
    local lost = records.usage.reserve(id, day, "interactive", 2, 900)
    records.usage.mark_dispatched(lost)
    -- Age both reservations past the stale window.
    storage.execute("UPDATE usage_reservation SET created_at = created_at - 3600000;")

    local released, retained = records.usage.sweep(60000)
    H.eq(released, 1, "pending expired")
    H.eq(retained, 1, "dispatched retained")
    local totals = records.usage.totals(id, day, "interactive")
    H.eq(totals.model_requests, 2, "crashed requests stay charged")
    H.eq(totals.est_tokens, 900, "reserved values retained conservatively")
    H.eq(totals.open_reservations, 0, "queue drained")
    local _ = never
  end)

  H.test("totals combine committed days with open cross-instance reservations", function()
    local id = project_id("usage-totals")
    local day = records.usage.today()
    local r1 = records.usage.reserve(id, day, "interactive", 1, 300)
    records.usage.commit_actual(r1, 350, 200, 150)
    records.usage.reserve(id, day, "interactive", 1, 120) -- another instance in flight
    local totals = records.usage.totals(id, day, "interactive")
    H.eq(totals.model_requests, 2, "committed plus in-flight")
    H.eq(totals.est_tokens, 470, "committed plus reserved")
  end)
end
