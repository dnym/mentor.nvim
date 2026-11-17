-- Integration: Implement mode end to end — target capture (multibyte, EOL,
-- linewise/charwise/point, blockwise refusal), policy-bounded targets, the
-- propose_edit tool through the agent loop with the scripted fake provider,
-- diff-preview buffers, explicit accept with stale revalidation and undo,
-- rejection leaving the buffer untouched, and the guarantee that Coach is
-- never offered propose_edit. No network.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local mentor = require("mentor")
local project = require("mentor.project")
local agent = require("mentor.agent")
local fake = require("mentor.provider.fake")
local storage = require("mentor.storage")
local chat = require("mentor.ui.chat")
local implement = require("mentor.implement")
local tools_mod = require("mentor.tools")

return function()
  ---Isolated environment with a fixture git repo; returns the project.
  local function configure(label, extra_config)
    chat.reset()
    project.reset()
    mentor.shutdown()
    storage.close()
    implement._reset()
    agent.provider = nil
    fake._scripted = nil
    fake.chunk_delay_ms = 1
    vim.cmd("silent! only")
    local opts = {
      dev = { fake_provider = true },
      data_dir = fs.tmpdir() .. "/data-imp-" .. label,
    }
    for k, v in pairs(extra_config or {}) do
      opts[k] = v
    end
    mentor.setup(opts)
    local dir = fs.git_repo(fs.tmpdir() .. "/imp-" .. label)
    fs.write(dir .. "/main.lua", "print('work in progress')")
    return project.for_dir(dir)
  end

  local function focus(proj, rel)
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/" .. (rel or "main.lua")))
  end

  ---Scripted single propose_edit turn; waits until the run settles with a
  ---pending proposal.
  local function propose(replacement)
    fake.script({
      { content = "", tool_calls = { { name = "propose_edit", arguments = { replacement = replacement } } } },
      { content = "ok" },
    })
    local handle = implement.start("do it", { range = 1, line1 = 1, line2 = 1, vmode = "" })
    H.ok(handle, "implement run started")
    local ok = vim.wait(5000, function()
      return implement.pending_count() > 0 and implement.active_count() == 0
    end, 5)
    H.ok(ok, "proposal recorded and run settled")
  end

  -- ---------------------------------------------------------------------
  -- Range conversion (defined once in the implement module)
  -- ---------------------------------------------------------------------

  H.test("range conversion handles multibyte text and end-of-line behavior", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "alpha", "pörä √√ hello", "omega" })
    local function text(range)
      return table.concat(
        vim.api.nvim_buf_get_text(buf, range.row1, range.col1, range.row2, range.col2, {}),
        "\n"
      )
    end

    -- "örä" spans multibyte characters: marks sit on byte columns.
    local r = implement._charwise_range(buf, 2, 2, 2, 5)
    H.ok(r, "charwise range accepted")
    H.eq(text(r), "örä", "multibyte selection maps to exact bytes")

    -- A mark at the virtual end-of-line (v$) selects to the actual EOL.
    -- Note: "√" is three bytes, so the column arithmetic below is byte-based.
    local line2 = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
    r = implement._charwise_range(buf, 2, 15, 2, #line2 + 1)
    H.eq(text(r), "hello", "selection ends exactly at the line end")

    -- Multi-line charwise includes the line breaks it crosses.
    r = implement._charwise_range(buf, 1, 3, 3, 1)
    H.eq(text(r), "pha\npörä √√ hello\no", "cross-line selection includes EOLs")

    -- Linewise covers whole lines: mid-buffer the EOL is materialized,
    -- while the last line has no trailing EOL to cover (eof-flagged).
    r = implement._linewise_range(buf, 2, 2)
    H.eq(text(r), "pörä √√ hello\n", "mid-buffer linewise range includes the EOL")
    r = implement._linewise_range(buf, 2, 3)
    H.ok(r and r.eof, "last-line linewise range is eof-marked")
    H.eq(text(r), "pörä √√ hello\nomega", "no phantom EOL past the last line")

    H.eq(implement._charwise_range(buf, 2, 5, 2, 2), nil, "reversed columns refused")
    H.eq(implement._linewise_range(buf, 2, 9), nil, "range past the buffer end refused")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  H.test("blockwise selections are refused with an explanation", function()
    local proj = configure("block")
    focus(proj)
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 1, 10, 0 })
    local target, err = implement._capture_target(proj, { range = 1, line1 = 1, line2 = 1, vmode = "\022" })
    H.eq(target, nil, "capture refused")
    H.contains_text(err, "blockwise", "refusal explains what to do instead")
  end)

  H.test("capture freezes the target for point, charwise, and linewise modes", function()
    local proj = configure("capture")
    focus(proj)

    vim.cmd("normal! gg0f(") -- land on "(" → 0-based byte column 6
    local target = implement._capture_target(proj, { range = 0, line1 = 1, line2 = 1, vmode = "" })
    H.eq(target.mode, "point", "no range means an insertion point")
    H.eq(target.text, "", "the point selects nothing")
    H.eq(target.range.row1, 0, "row is 0-based")
    H.eq(target.range.col1, 5, "column is a 0-based byte column")
    H.ok(type(target.changedtick) == "number", "buffer version captured")

    vim.fn.setpos("'<", { 0, 1, 7, 0 })
    vim.fn.setpos("'>", { 0, 1, 9, 0 })
    target = implement._capture_target(proj, { range = 1, line1 = 1, line2 = 1, vmode = "v" })
    H.eq(target.mode, "charwise", "live visual marks are honored")
    H.eq(target.text, "'wo", "charwise text is exact")

    target = implement._capture_target(proj, { range = 1, line1 = 1, line2 = 1, vmode = "" })
    H.eq(target.mode, "linewise", "an explicit numeric range behaves linewise")
    H.ok(target.range.eof, "the single-line file is an eof-adjacent linewise range")
    H.eq(target.text, "print('work in progress')", "linewise text of the last line has no phantom EOL")
  end)

  H.test("capture refuses off-limits paths and unmodifiable buffers", function()
    local proj = configure("refuse")
    fs.write(proj.root .. "/.env", "API_KEY=abc\n")
    focus(proj, ".env")
    local _, err = implement._capture_target(proj, { range = 0, line1 = 1, line2 = 1, vmode = "" })
    H.contains_text(err, "off-limits", "credential path refused before any model call")

    focus(proj)
    vim.bo[0].modifiable = false
    _, err = implement._capture_target(proj, { range = 0, line1 = 1, line2 = 1, vmode = "" })
    H.contains_text(err, "modifiable", "unmodifiable buffer refused")
    vim.bo[0].modifiable = true
  end)

  H.test("propose_edit validates like every tool and refuses without an active run", function()
    local proj = configure("guard")
    local ctx = tools_mod.new_operation({ project = proj })

    local r = tools_mod.run(ctx, "propose_edit", { replacement = "x", path = "elsewhere.lua" })
    H.ok(not r.ok, "unknown parameters rejected")
    H.contains_text(r.error, "unknown parameter path", "the model cannot smuggle a new target")

    r = tools_mod.run(ctx, "propose_edit", {})
    H.contains_text(r.error, "missing required parameter replacement", "replacement is required")

    -- Empty replacement is schema-valid text (it means deletion); only an
    -- active captured target gives it meaning.
    r = tools_mod.run(ctx, "propose_edit", { replacement = "" })
    H.ok(not r.ok, "no proposal without an explicit run")
    H.contains_text(r.error, "no Implement run", "the target comes from the developer's command")
  end)

  -- ---------------------------------------------------------------------
  -- Propose -> preview -> accept -> undo
  -- ---------------------------------------------------------------------

  H.test("an insertion point lands at the cursor, not on the line below", function()
    local proj = configure("point-row")
    focus(proj)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first", "second", "third" })
    vim.cmd("normal! ggj0ll") -- line 2, on the "c" of "second"
    local target = implement._capture_target(proj, { range = 0, line1 = 2, line2 = 2, vmode = "" })
    H.eq(target.range.row1, 1, "cursor line 2 is 0-based row 1")
    H.eq(target.range.col1, 2, "cursor column kept")

    vim.cmd("normal! G$") -- last line, last column: must stay in bounds
    target = implement._capture_target(proj, { range = 0, line1 = 3, line2 = 3, vmode = "" })
    H.eq(target.range.row1, 2, "last line maps to the last row")

    vim.cmd("normal! ggj0ll")
    fake.script({
      { content = "", tool_calls = { { name = "propose_edit", arguments = { replacement = "<HERE>" } } } },
      { content = "ok" },
    })
    H.ok(implement.start("mark it", { range = 0, line1 = 2, line2 = 2, vmode = "" }), "run started")
    vim.wait(5000, function()
      return implement.pending_count() > 0 and implement.active_count() == 0
    end, 5)
    H.ok(implement.accept(), "accepted")
    H.eq(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      { "first", "se<HERE>cond", "third" },
      "text inserted at the cursor"
    )
  end)

  H.test("a run opens no window; it reports through notifications and the log", function()
    local proj = configure("quiet-run")
    focus(proj)
    local wins_before = #vim.api.nvim_list_wins()
    local tabs_before = #vim.api.nvim_list_tabpages()
    local notes = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
    local ok_run, run_err = pcall(propose, "-- quiet\n")
    vim.notify = orig_notify
    H.ok(ok_run, tostring(run_err))
    H.eq(#vim.api.nvim_list_wins(), wins_before, "no split while running or on the proposal")
    H.eq(#vim.api.nvim_list_tabpages(), tabs_before, "no tab until the developer asks")
    H.contains_text(notes[1] and notes[1].msg, "Implement running on line 1 of main.lua", "start notified")
    H.contains_text(notes[#notes] and notes[#notes].msg, ":MentorImplementReview", "ready notification")

    -- The log is one reusable Markdown buffer per project.
    H.ok(implement.open_log(), "log opens")
    local log = vim.api.nvim_get_current_buf()
    H.eq(vim.api.nvim_buf_get_name(log), "mentor://implement-run/" .. proj.identity, "per-project name")
    H.eq(vim.bo[log].filetype, "markdown", "Markdown log")
    local text = table.concat(vim.api.nvim_buf_get_lines(log, 0, -1, false), "\n")
    H.contains_text(text, "## line 1 of main.lua", "a section per run")
    H.contains_text(text, "⌁ propose_edit", "tool activity as a note line")
    H.contains_text(text, "⌁ Finished. Proposal #", "outcome note")
    implement.reject()
    focus(proj)
    propose("-- again\n")
    H.eq(vim.api.nvim_buf_get_name(log), "mentor://implement-run/" .. proj.identity, "same log buffer")
    local sections = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(log, 0, -1, false)) do
      if line:match("^## ") then
        sections = sections + 1
      end
    end
    H.eq(sections, 2, "the second run appended to the same log")
    H.ok(implement.open_log(), "reopening reuses the window")
    H.eq(#vim.fn.win_findbuf(log), 1, "log shown once")
  end)

  H.test("review opens a diff tab of the whole file; accept closes it and returns", function()
    local proj = configure("review")
    focus(proj)
    local main_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(
      main_buf,
      0,
      -1,
      false,
      { "local a = 1", "print('work in progress')", "return a" }
    )
    local origin = vim.api.nvim_get_current_win()
    local tabs_before = #vim.api.nvim_list_tabpages()
    fake.script({
      -- No trailing newline: a mid-buffer linewise range still gets whole
      -- lines back instead of swallowing the next line.
      {
        content = "",
        tool_calls = { { name = "propose_edit", arguments = { replacement = "print('done')" } } },
      },
      { content = "ok" },
    })
    H.ok(implement.start("finish", { range = 1, line1 = 2, line2 = 2, vmode = "" }), "run started")
    H.ok(
      vim.wait(5000, function()
        return implement.pending_count() > 0 and implement.active_count() == 0
      end, 5),
      "proposal recorded"
    )

    local p = implement.review("")
    H.ok(p, "review opened")
    H.eq(#vim.api.nvim_list_tabpages(), tabs_before + 1, "one new tab")
    local cur = vim.fn.bufnr("mentor://implement/" .. p.id .. "/current")
    local prop = vim.fn.bufnr("mentor://implement/" .. p.id .. "/proposed")
    H.eq(
      vim.api.nvim_buf_get_lines(cur, 0, -1, false),
      { "local a = 1", "print('work in progress')", "return a" },
      "left side is the whole current file"
    )
    H.eq(
      vim.api.nvim_buf_get_lines(prop, 0, -1, false),
      { "local a = 1", "print('done')", "return a" },
      "right side is the whole file as accepting would leave it"
    )
    H.eq(vim.bo[prop].filetype, vim.bo[main_buf].filetype, "the file's own highlighting")
    local diffs = 0
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[w].diff then
        diffs = diffs + 1
      end
    end
    H.eq(diffs, 2, "the two sides are in diff mode")
    H.ok(
      #vim.fn.win_findbuf(vim.fn.bufnr("mentor://implement-run/" .. proj.identity)) == 1,
      "log shown below"
    )
    H.eq(vim.api.nvim_get_current_buf(), prop, "cursor on the proposed side")
    H.ok(rawequal(implement.review(), p), "reviewing again switches to the open tab")
    H.eq(#vim.api.nvim_list_tabpages(), tabs_before + 1, "no second tab")

    -- q closes without deciding.
    vim.cmd("normal q")
    H.eq(#vim.api.nvim_list_tabpages(), tabs_before, "tab closed")
    H.eq(vim.api.nvim_get_current_win(), origin, "back where the review was opened")
    H.eq(implement.pending_count(), 1, "still pending")

    -- a accepts from the tab.
    implement.review()
    vim.cmd("normal a")
    H.eq(#vim.api.nvim_list_tabpages(), tabs_before, "accept closed the tab")
    H.eq(vim.api.nvim_get_current_win(), origin, "back at the origin window")
    H.eq(
      vim.api.nvim_buf_get_lines(main_buf, 0, -1, false),
      { "local a = 1", "print('done')", "return a" },
      "applied"
    )
    H.eq(vim.fn.bufnr("mentor://implement/" .. p.id .. "/proposed"), -1, "review buffers gone")
  end)

  H.test("rejecting by command closes an open review tab too", function()
    local proj = configure("review-reject")
    focus(proj)
    local tabs_before = #vim.api.nvim_list_tabpages()
    propose("-- nope\n")
    H.ok(implement.review(), "review opened")
    H.ok(implement.reject(""), "rejected")
    H.eq(#vim.api.nvim_list_tabpages(), tabs_before, "tab closed")
    local _, err = implement.review()
    H.contains_text(err, "no pending", "nothing left to review")
  end)

  H.test("a proposal previews in diff buffers; accept applies it and one undo reverts", function()
    local proj = configure("accept")
    focus(proj)
    vim.cmd("normal! gg0") -- insertion point at the very start of line 1

    fake.script({
      {
        content = "",
        tool_calls = {
          {
            name = "propose_edit",
            arguments = {
              replacement = "-- entry point banner\n",
              explanation = "adds the standard banner",
            },
          },
        },
      },
      { content = "Added the banner." },
    })
    local handle = implement.start("add a banner comment", { range = 0, line1 = 1, line2 = 1, vmode = "" })
    H.ok(handle, "run started")
    local ok = vim.wait(5000, function()
      return implement.pending_count() > 0 and implement.active_count() == 0
    end, 5)
    H.ok(ok, "proposal recorded")
    H.ok(implement.review(), "review opened")

    local previews = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(b)
      if name:find("^mentor://implement/%d+/", 1) then
        previews[name] = b
      end
    end
    local found_current, found_proposed = false, false
    for name in pairs(previews) do
      found_current = found_current or name:match("/current$") ~= nil
      found_proposed = found_proposed or name:match("/proposed$") ~= nil
    end
    H.ok(found_current and found_proposed, "current and proposed preview buffers exist")

    local applied, err = implement.accept()
    H.ok(applied, "accept succeeded: " .. tostring(err))
    focus(proj)
    H.eq(
      vim.api.nvim_buf_get_lines(vim.fn.bufnr(proj.root .. "/main.lua"), 0, -1, false),
      { "-- entry point banner", "print('work in progress')" },
      "replacement applied at the point"
    )
    H.eq(
      vim.fn.readfile(proj.root .. "/main.lua"),
      { "print('work in progress')" },
      "nothing was written to disk"
    )

    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/main.lua"))
    vim.cmd("normal! u")
    H.eq(
      vim.api.nvim_buf_get_lines(vim.fn.bufnr(proj.root .. "/main.lua"), 0, -1, false),
      { "print('work in progress')" },
      "one undo reverts the whole application"
    )
    H.eq(implement.pending_count(), 0, "no proposal remains pending")
  end)

  H.test("a linewise proposal replaces whole lines", function()
    local proj = configure("linewise")
    focus(proj)
    propose("print('done')\n")
    local applied = implement.accept()
    H.ok(applied, "accepted")
    H.eq(
      vim.api.nvim_buf_get_lines(vim.fn.bufnr(proj.root .. "/main.lua"), 0, -1, false),
      { "print('done')" },
      "the whole line was replaced"
    )
  end)

  H.test("a replacement identical to the target produces no proposal", function()
    local proj = configure("identical")
    focus(proj)
    fake.script({
      {
        content = "",
        tool_calls = {
          { name = "propose_edit", arguments = { replacement = "print('work in progress')\n" } },
        },
      },
      { content = "nothing to change" },
    })
    local handle = implement.start("make it identical", { range = 1, line1 = 1, line2 = 1, vmode = "" })
    H.ok(handle, "run started")
    vim.wait(5000, function()
      return implement.active_count() == 0
    end, 5)
    H.eq(implement.pending_count(), 0, "the no-op proposal was refused")
  end)

  H.test("repeated proposals supersede; only the newest stays pending", function()
    local proj = configure("supersede")
    focus(proj)
    fake.script({
      { content = "", tool_calls = { { name = "propose_edit", arguments = { replacement = "-- A\n" } } } },
      { content = "", tool_calls = { { name = "propose_edit", arguments = { replacement = "-- B\n" } } } },
      { content = "second thought applied" },
    })
    local handle = implement.start("banner", { range = 0, line1 = 1, line2 = 1, vmode = "" })
    H.ok(handle, "run started")
    vim.wait(5000, function()
      return implement.active_count() == 0
    end, 5)
    H.eq(implement.pending_count(), 1, "exactly one pending proposal survives")
    H.ok(implement.accept(), "accepted the newest")
    H.eq(
      vim.api.nvim_buf_get_lines(vim.fn.bufnr(proj.root .. "/main.lua"), 0, -1, false),
      { "-- B", "print('work in progress')" },
      "the newest replacement was applied"
    )
  end)

  -- ---------------------------------------------------------------------
  -- Stale proposals and rejection
  -- ---------------------------------------------------------------------

  H.test("intervening edits — including edit-and-undo — invalidate the proposal", function()
    local proj = configure("stale-edit")
    focus(proj)
    propose("-- banner\n")
    vim.api.nvim_buf_set_text(vim.fn.bufnr(proj.root .. "/main.lua"), 0, 0, 0, 0, { "  " })
    local applied, err = implement.accept()
    H.eq(applied, nil, "accept refused")
    H.contains_text(err, "changed since the proposal", "staleness is explained")
  end)

  H.test("edit and undo still invalidate the proposal", function()
    local proj = configure("stale-undo")
    focus(proj)
    propose("-- banner\n")
    focus(proj)
    vim.cmd("normal! A!") -- append "!" then undo: content is back, the version is not
    vim.cmd("normal! u")
    H.eq(
      vim.api.nvim_buf_get_lines(vim.fn.bufnr(proj.root .. "/main.lua"), 0, -1, false),
      { "print('work in progress')" },
      "buffer content is back to the original"
    )
    local applied, err = implement.accept()
    H.eq(applied, nil, "accept refused despite identical content")
    H.contains_text(err, "changed since the proposal", "the version, not the text, decides")
  end)

  H.test("closing the target or making it unmodifiable invalidates the proposal", function()
    local proj = configure("stale-close")
    focus(proj)
    propose("-- banner\n")
    vim.api.nvim_buf_delete(vim.fn.bufnr(proj.root .. "/main.lua"), { force = true })
    focus(proj) -- a fresh buffer for the same file is not the captured target
    local applied, err = implement.accept()
    H.eq(applied, nil, "accept refused after the buffer was wiped")
    H.contains_text(err, "buffer", "closure is explained")

    focus(proj)
    propose("-- banner2\n")
    vim.bo[vim.fn.bufnr(proj.root .. "/main.lua")].modifiable = false
    applied, err = implement.accept()
    H.eq(applied, nil, "accept refused after modifiability was removed")
    H.contains_text(err, "modifiable", "writability is explained")
    vim.bo[vim.fn.bufnr(proj.root .. "/main.lua")].modifiable = true
  end)

  H.test("rejection leaves the target buffer untouched", function()
    local proj = configure("reject")
    focus(proj)
    propose("-- banner\n")
    local buf = vim.fn.bufnr(proj.root .. "/main.lua")
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local rejected, err = implement.reject()
    H.ok(rejected, "rejected: " .. tostring(err))
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before, "buffer unchanged")
    local rejected_again, err2 = implement.reject()
    H.eq(rejected_again, nil, "nothing left to reject")
    H.contains_text(err2, "no pending", "clear follow-up message")
    H.eq(implement.accept(), nil, "a rejected proposal cannot be applied")
  end)

  H.test("a run stopped by a budget says which limit it hit", function()
    local proj = configure("budget-note", { limits = { interactive = { model_requests = 1 } } })
    focus(proj)
    fake.script({
      { content = "", tool_calls = { { name = "read_file", arguments = { path = "main.lua" } } } },
      { content = "never reached" },
    })
    H.ok(implement.start("do it", { range = 1, line1 = 1, line2 = 1, vmode = "" }), "run started")
    vim.wait(5000, function()
      return implement.active_count() == 0
    end, 5)
    local run_buf = vim.fn.bufnr("mentor://implement-run/" .. proj.identity)
    local text = table.concat(vim.api.nvim_buf_get_lines(run_buf, 0, -1, false), "\n")
    H.contains_text(text, "model request limit", "the session note names the limit")
  end)

  H.test("the commands without an id act on the newest pending proposal", function()
    local proj = configure("bare-commands")
    focus(proj)
    propose("-- first\n")
    local buf = vim.fn.bufnr(proj.root .. "/main.lua")
    local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- User commands pass "" for a missing argument, not nil.
    local rejected, rerr = implement.reject("")
    H.ok(rejected, "bare reject works: " .. tostring(rerr))
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before, "reject left the buffer untouched")
    focus(proj)
    propose("-- second\n")
    local applied, aerr = implement.accept("")
    H.ok(applied, "bare accept works: " .. tostring(aerr))
    H.eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], "-- second", "the newest proposal was applied")
    local _, uerr = implement.accept("abc")
    H.contains_text(uerr, "usage", "a non-numeric id is still refused")
  end)

  H.test("MentorStop cancels an implement run and withdraws its pending proposal", function()
    local proj = configure("stop")
    focus(proj)
    fake.chunk_delay_ms = 100 -- hold the stream open long enough to cancel mid-turn
    fake.script({
      { content = "s t r e a m i n g  a  l o n g  p a u s e  t h a t  w i l l  b e  c a n c e l l e d" },
      { content = "", tool_calls = { { name = "propose_edit", arguments = { replacement = "-- late\n" } } } },
      { content = "late proposal" },
    })
    local handle = implement.start("slow one", { range = 1, line1 = 1, line2 = 1, vmode = "" })
    H.ok(handle, "run started")
    vim.wait(150, function()
      return handle:is_active()
    end, 5)
    H.eq(implement.stop(), 1, "one active run cancelled")
    vim.wait(3000, function()
      return implement.active_count() == 0
    end, 5)
    H.eq(implement.pending_count(), 0, "no proposal survives a cancelled run")
    fake.chunk_delay_ms = 1
  end)

  -- ---------------------------------------------------------------------
  -- Coach isolation
  -- ---------------------------------------------------------------------

  H.test("Coach is never offered propose_edit", function()
    local proj = configure("coach")
    focus(proj)
    local reqs = {}
    agent.provider = {
      chat = function(req)
        reqs[#reqs + 1] = req
        return fake.chat(req)
      end,
    }
    fake.script({ { content = "hi there" } })
    vim.cmd("MentorChat")
    chat.ask("hello")
    local ok = vim.wait(3000, function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end, 5)
    H.ok(ok, "coach turn completed")
    H.ok(#reqs > 0, "a request was dispatched")

    local names = {}
    for _, schema in ipairs(reqs[1].tools or {}) do
      names[schema["function"].name] = true
    end
    H.ok(next(names) ~= nil, "tools were sent")
    H.ok(names.read_file, "investigation tools present")
    H.ok(names.memory_list, "memory tools present")
    H.eq(names.propose_edit, nil, "the implement group is invisible to Coach")
    H.ok(
      not (reqs[1].messages[1].content or ""):find("propose_edit", 1, true),
      "the Coach system prompt never mentions propose_edit"
    )
    agent.provider = nil
  end)
end
