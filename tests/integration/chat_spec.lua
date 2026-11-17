-- Integration: the Coach scratch buffer driven by the fake asynchronous
-- provider — streaming delivery, cancellation, automatic queuing of
-- additional requests, transcript persistence across buffer reopen, and
-- project binding that survives focus changes.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local mentor = require("mentor")
local project = require("mentor.project")
local chat = require("mentor.ui.chat")
local storage = require("mentor.storage")
local fake = require("mentor.provider.fake")

return function()
  ---Resets transient state and configures an isolated environment.
  local function configure(label)
    chat.reset()
    project.reset()
    storage.close() -- reopen against this test's data dir
    fake._scripted = nil
    fake.chunk_delay_ms = 5
    mentor.setup({
      dev = { fake_provider = true },
      data_dir = fs.tmpdir() .. "/data-" .. label,
    })
  end

  ---Edits a file in the current window so project focus follows it.
  local function edit_git_project(label)
    local dir = fs.git_repo(fs.tmpdir() .. "/" .. label)
    local file = fs.write(dir .. "/main.lua", "print('work in progress')\n")
    vim.cmd("silent! edit " .. vim.fn.fnameescape(file))
    return dir, file
  end

  local function wait_until(pred, ms)
    local ok = vim.wait(ms or 3000, pred, 5)
    H.ok(ok, "condition not met within " .. tostring(ms or 3000) .. "ms")
  end

  local function words(prefix, n)
    local out = {}
    for i = 1, n do
      out[i] = prefix .. i
    end
    return table.concat(out, " ")
  end

  local function chat_text()
    return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(0), 0, -1, false), "\n")
  end

  H.test("opening Coach focuses a project-bound scratch buffer", function()
    configure("open")
    local dir = edit_git_project("openproj")
    vim.cmd("MentorChat")
    H.contains_text(vim.api.nvim_buf_get_name(0), "mentor://coach/", "chat buffer name")
    H.eq(vim.b[0].mentor_project, project.canonical(dir), "project binding")
    H.eq(vim.bo[0].buftype, "nofile", "scratch buffer")
    H.contains_text(chat_text(), "# Mentor Coach", "header present")
  end)

  H.test("opening Coach twice reuses the same window", function()
    configure("reuse")
    edit_git_project("reuseproj")
    vim.cmd("MentorChat")
    local win = vim.api.nvim_get_current_win()
    vim.cmd("MentorChat")
    H.eq(vim.api.nvim_get_current_win(), win, "same window")
  end)

  H.test("asking streams the scripted response and records usage", function()
    configure("stream")
    edit_git_project("streamproj")
    vim.cmd("MentorChat")
    fake.script({ "alpha beta gamma delta" })
    vim.cmd("MentorChatAsk how do I structure this module?")
    wait_until(function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end)
    local text = chat_text()
    H.contains_text(text, "> how do I structure this module?", "user line recorded")
    H.contains_text(text, "alpha beta gamma delta", "full response streamed")
    H.contains_text(text, "1 model request(s)", "usage note")
  end)

  H.test("responses arrive incrementally while the editor stays responsive", function()
    configure("incremental")
    edit_git_project("incproj")
    fake.chunk_delay_ms = 15
    vim.cmd("MentorChat")
    fake.script({ words("word", 60) })
    vim.cmd("MentorChatAsk long answer please")
    -- The editor must keep accepting commands while streaming.
    H.eq(vim.api.nvim_eval("1 + 1"), 2, "editor responds during streaming")
    vim.wait(120)
    local partial = chat_text()
    H.contains_text(partial, "word1", "streaming has begun")
    H.ok(not partial:find("word60", 1, true), "stream not finished yet")
    wait_until(function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end)
    H.contains_text(chat_text(), "word60", "completed eventually")
  end)

  H.test("MentorStop cancels streaming and later deltas do not land", function()
    configure("cancel")
    edit_git_project("cancleproj")
    fake.chunk_delay_ms = 15
    vim.cmd("MentorChat")
    fake.script({ words("chunk", 80) })
    vim.cmd("MentorChatAsk please stream slowly")
    vim.wait(120)
    vim.cmd("MentorStop")
    H.eq(chat.active_count(), 0, "cancelled immediately")
    local snapshot = chat_text()
    H.ok(not snapshot:find("chunk80", 1, true), "cancelled before completion")
    vim.wait(200)
    H.eq(chat_text(), snapshot, "no late deltas after cancellation")
  end)

  H.test("additional requests queue automatically and run in order", function()
    configure("queue")
    edit_git_project("queueproj")
    fake.chunk_delay_ms = 10
    vim.cmd("MentorChat")
    fake.script({ words("first", 25), "second answer" })
    local ok1 = chat.ask("first question")
    local ok2 = chat.ask("second question")
    H.ok(ok1 and ok2, "both asks accepted")
    H.eq(chat.active_count(), 1, "one operation active")
    H.eq(chat.queued_count(), 1, "second request queued")
    H.contains_text(chat_text(), "⌁ queued", "queue notice")
    wait_until(function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end)
    local text = chat_text()
    local first_at = text:find("first1", 1, true)
    local second_at = text:find("second answer", 1, true)
    H.ok(first_at and second_at, "both answers present")
    H.ok(first_at < second_at, "answers ran in order")
  end)

  H.test("the transcript persists and resumes after the buffer closes", function()
    configure("resume")
    edit_git_project("resumeproject")
    vim.cmd("MentorChat")
    fake.script({ "the answer holds the concept" })
    chat.ask("explain this pattern")
    wait_until(function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end)

    -- Close the buffer and forget in-memory state, then reopen Coach: the
    -- conversation must be rendered from storage.
    local buf = vim.api.nvim_get_current_buf()
    chat.reset()
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.cmd("MentorChat")
    local text = chat_text()
    H.contains_text(text, "> explain this pattern", "persisted user turn")
    H.contains_text(text, "the answer holds the concept", "persisted assistant turn")
  end)

  H.test("reply tables are aligned in the view once complete; storage keeps raw text", function()
    configure("tables")
    edit_git_project("tablesproj")
    vim.cmd("MentorChat")
    local raw = "Compare:\n|Name|Size|\n|-|-:|\n|alpha|1|\n|b|12345|\ndone"
    fake.script({ raw })
    chat.ask("compare them")
    wait_until(function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end)
    local aligned = table.concat({
      "| Name  |  Size |",
      "| ----- | ----: |",
      "| alpha |     1 |",
      "| b     | 12345 |",
    }, "\n")
    H.contains_text(chat_text(), "Compare:\n" .. aligned .. "\ndone", "aligned after streaming")

    local proj = project.for_dir(vim.b[0].mentor_project)
    local rows = require("mentor.storage.records").conversations.load(
      require("mentor.storage.records").projects.touch({ identity = proj.identity, root = proj.root }),
      "coach"
    )
    H.eq(rows[#rows].content, raw, "stored transcript keeps the model's text")

    local buf = vim.api.nvim_get_current_buf()
    chat.reset()
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.cmd("MentorChat")
    H.contains_text(chat_text(), aligned, "replayed transcript aligned too")
  end)

  H.test("assistant turns with native tool calls render as activity notes", function()
    configure("toolnote")
    edit_git_project("toolnoteproject")
    vim.cmd("MentorChat")
    fake.script({
      { content = "", tool_calls = { { name = "read_file", arguments = { path = "main.lua" } } } },
      { content = "now I can explain" },
    })
    chat.ask("what does main.lua do?")
    wait_until(function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end)
    local text = chat_text()
    H.contains_text(text, "⌁ read_file main.lua", "tool activity line")
    H.contains_text(text, "now I can explain", "final answer after tool roundtrip")
  end)

  H.test("each project gets its own chat and keeps its binding", function()
    configure("binding")
    local dir_a = edit_git_project("proj-a")
    local source_win = vim.api.nvim_get_current_win()
    vim.cmd("MentorChat") -- chat for A
    local chat_a = vim.api.nvim_win_get_buf(0)

    -- Focus a different project in the original window: A's chat must stay
    -- bound to A and background focus moves to B.
    vim.api.nvim_set_current_win(source_win)
    local dir_b = edit_git_project("proj-b")
    vim.cmd("MentorChat") -- opens a separate chat for B
    local chat_b = vim.api.nvim_win_get_buf(0)
    H.neq(chat_b, chat_a, "separate chat buffer per project")

    H.eq(vim.b[chat_a].mentor_project, project.canonical(dir_a), "A binding preserved")
    H.eq(project.for_buf(chat_a).identity, project.canonical(dir_a), "A chat resolves to A")
    H.eq(project.for_buf(chat_b).identity, project.canonical(dir_b), "B chat resolves to B")
  end)

  ---Every tool message must answer a call of the assistant turn it follows.
  local function assert_tool_pairing(messages, label)
    local open_ids = nil
    for i, m in ipairs(messages) do
      if m.role == "tool" then
        H.ok(
          open_ids and open_ids[m.tool_call_id],
          label .. ": tool message " .. i .. " answers a preceding call"
        )
        if open_ids then
          open_ids[m.tool_call_id] = nil
        end
      else
        if open_ids then
          H.eq(next(open_ids), nil, label .. ": every call before message " .. i .. " was answered")
        end
        open_ids = nil
        if m.role == "assistant" and m.tool_calls then
          open_ids = {}
          for _, call in ipairs(m.tool_calls) do
            open_ids[call.id] = true
          end
        end
      end
    end
    if open_ids then
      H.eq(next(open_ids), nil, label .. ": trailing calls answered")
    end
  end

  H.test("a turn stopped mid tool batch replays as a valid history", function()
    configure("midbatch")
    mentor.setup({
      dev = { fake_provider = true },
      data_dir = fs.tmpdir() .. "/data-midbatch",
      limits = { interactive = { tool_calls = 1 } },
    })
    edit_git_project("midbatchproj")
    vim.cmd("MentorChat")
    local call = { name = "read_file", arguments = { path = "main.lua" } }
    fake.script({
      {
        content = "",
        tool_calls = { call, { id = "fake_call_2", name = "read_file", arguments = { path = "main.lua" } } },
      },
      { content = "second answer" },
    })
    local real_chat = fake.chat
    local sent
    fake.chat = function(req)
      sent = req.messages
      return real_chat(req)
    end
    local ok, err = pcall(function()
      chat.ask("first")
      wait_until(function()
        return chat.active_count() == 0 and chat.queued_count() == 0
      end)
      H.contains_text(chat_text(), "tool call limit", "first turn stopped mid-batch")
      chat.ask("second")
      wait_until(function()
        return chat.active_count() == 0 and chat.queued_count() == 0
      end)
    end)
    fake.chat = real_chat
    H.ok(ok, tostring(err))
    assert_tool_pairing(sent, "replayed history")
    local kept = 0
    for _, m in ipairs(sent) do
      if m.role == "tool" then
        kept = kept + 1
      end
    end
    H.eq(kept, 1, "the answered call and its result are kept")
    H.contains_text(chat_text(), "second answer", "follow-up succeeds")
  end)

  H.test("orphan tool messages and unanswered calls are dropped from replay", function()
    local out = chat._pair_tool_messages({
      { role = "user", content = "q" },
      { role = "tool", tool_call_id = "x", content = "orphan" },
      { role = "assistant", content = "", tool_calls = { { id = "a" }, { id = "b" } } },
      { role = "tool", tool_call_id = "a", content = "ra" },
      { role = "user", content = "q2" },
      { role = "assistant", content = "", tool_calls = { { id = "c" } } },
      { role = "assistant", content = "done" },
    })
    assert_tool_pairing(out, "paired")
    H.eq(#out, 6, "orphan tool message removed")
    H.eq(#out[2].tool_calls, 1, "unanswered call removed, answered call kept")
    H.eq(out[5].tool_calls, nil, "fully unanswered call list removed")
  end)

  H.test("history trimming never separates tool calls from their results", function()
    configure("trim")
    mentor.setup({
      dev = { fake_provider = true },
      data_dir = fs.tmpdir() .. "/data-trim",
      chat = { history_max_tokens = 400 },
    })
    local big = words("w", 120)
    local history = {
      { role = "user", content = big },
      { role = "assistant", content = "", tool_calls = { { id = "a" } } },
      { role = "tool", tool_call_id = "a", content = big },
      { role = "assistant", content = big },
      { role = "user", content = "latest question" },
      { role = "assistant", content = "", tool_calls = { { id = "b" } } },
      { role = "tool", tool_call_id = "b", content = "small" },
    }
    local out = chat._build_request_messages("sys", history)
    H.eq(out[1].role, "system", "system prompt first")
    H.eq(out[2].role, "user", "history starts at a user message")
    H.eq(out[2].content, "latest question", "older turns trimmed")
    assert_tool_pairing(out, "trimmed")
    local tiny = chat._build_request_messages("sys", { history[1], history[2], history[3] })
    H.eq(#tiny, 4, "the newest turn is always kept whole")
  end)

  H.test("the transcript renders as Markdown and replies stay out of the quote", function()
    configure("markdown")
    edit_git_project("mdproj")
    vim.cmd("MentorChat")
    local buf = vim.api.nvim_get_current_buf()
    H.ok(vim.treesitter.highlighter.active[buf] ~= nil, "treesitter highlighter attached")
    H.eq(vim.treesitter.get_parser(buf):lang(), "markdown", "markdown parser")
    H.eq(vim.wo.conceallevel, 2, "markup concealed in the chat window")

    fake.chunk_delay_ms = 10
    fake.script({ words("first", 10), "**bold** answer" })
    chat.ask("first question")
    chat.ask("second question")
    wait_until(function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:sub(1, 2) == "> " and i > 1 then
        H.eq(lines[i + 1], "", "blank line ends the quote after: " .. line)
      end
      H.neq(line, "⌁ queued", "queued placeholder removed once running")
    end
    H.contains_text(chat_text(), "**bold** answer", "markup text kept intact")

    -- Header rows are never sent by <CR>.
    vim.cmd("normal! gg")
    vim.cmd("normal! j")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    H.eq(chat.active_count() + chat.queued_count(), 0, "header line not sent")
  end)

  H.test("chat.markdown = false leaves the chat buffer plain", function()
    chat.reset()
    project.reset()
    storage.close()
    mentor.setup({
      dev = { fake_provider = true },
      data_dir = fs.tmpdir() .. "/data-plain",
      chat = { markdown = false },
    })
    edit_git_project("plainproj")
    vim.cmd("MentorChat")
    local buf = vim.api.nvim_get_current_buf()
    H.ok(vim.treesitter.highlighter.active[buf] == nil, "no treesitter highlighter")
    H.eq(vim.bo[buf].filetype, "mentorchat", "filetype still set")
  end)

  H.test(":bdelete on the chat buffer does not leave an unbound shell behind", function()
    configure("bdelete")
    local dir = edit_git_project("bdproj")
    vim.cmd("MentorChat")
    fake.script({ "noted your preference", "hooks run in phases" })
    chat.ask("please remember I know C")
    wait_until(function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end)
    local old = vim.api.nvim_get_current_buf()
    vim.cmd("bdelete")
    vim.wait(50, function()
      return not vim.api.nvim_buf_is_valid(old)
    end, 5)
    H.ok(not vim.api.nvim_buf_is_valid(old), "unloaded chat view is wiped")

    -- Asking from a source buffer reopens a bound view with the transcript.
    vim.cmd("silent! edit " .. vim.fn.fnameescape(dir .. "/main.lua"))
    local ok, err = chat.ask("where should counting happen?")
    H.ok(ok, "ask after :bdelete succeeds: " .. tostring(err))
    wait_until(function()
      return chat.active_count() == 0 and chat.queued_count() == 0
    end)
    local buf = vim.api.nvim_win_get_buf(0)
    H.contains_text(vim.api.nvim_buf_get_name(buf), "mentor://coach/", "back in the chat view")
    H.eq(vim.b[buf].mentor_project, project.canonical(dir), "project binding restored")
    H.eq(vim.bo[buf].buftype, "nofile", "still a scratch buffer")
    local text = chat_text()
    H.contains_text(text, "> please remember I know C", "earlier turn re-rendered")
    H.contains_text(text, "hooks run in phases", "new answer streamed")
    H.ok(vim.fn.maparg("<CR>", "n", false, true).buffer == 1, "<CR> mapping restored")
  end)
  H.test("<CR> on a typed draft sends it once; transcript lines stay put", function()
    configure("crdraft")
    edit_git_project("crproj")
    vim.cmd("MentorChat")
    local buf = vim.api.nvim_get_current_buf()
    local press = function()
      vim.fn.maparg("<CR>", "n", false, true).callback()
      wait_until(function()
        return chat.active_count() == 0 and chat.queued_count() == 0
      end)
    end
    local count = function(needle)
      local n = 0
      for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if l == needle then
          n = n + 1
        end
      end
      return n
    end

    fake.script({ "first answer", "second answer", "third answer" })
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "> foo" })
    vim.cmd("normal! G")
    press()
    H.eq(count("> foo"), 1, "typed draft is not duplicated")
    H.contains_text(chat_text(), "first answer", "draft was sent")

    -- Re-sending a rendered transcript line keeps it and appends a new turn.
    vim.fn.search("^> foo$")
    press()
    H.eq(count("> foo"), 2, "re-send appends a copy, original kept")

    -- Editing an earlier transcript line sends the edit and restores the line.
    vim.fn.cursor(1, 1)
    vim.fn.search("^> foo$")
    local r = vim.api.nvim_win_get_cursor(0)[1] - 1
    vim.api.nvim_buf_set_text(buf, r, 2, r, 5, { "bar" }) -- in-line edit, like `cw`
    press()
    H.eq(count("> foo"), 2, "edited transcript line restored")
    H.eq(count("> bar"), 1, "edited text sent once")
  end)
end
