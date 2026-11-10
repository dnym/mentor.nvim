-- Integration: the Coach scratch buffer driven by the fake asynchronous
-- provider — streaming delivery, cancellation, single-operation guard, and
-- project binding that survives focus changes.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local mentor = require("mentor")
local project = require("mentor.project")
local chat = require("mentor.ui.chat")
local fake = require("mentor.provider.fake")

return function()
  ---Resets transient state and configures an isolated environment.
  local function configure(label)
    chat.reset()
    project.reset()
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

  H.test("asking streams the full scripted response into the buffer", function()
    configure("stream")
    edit_git_project("streamproj")
    vim.cmd("MentorChat")
    fake.script({ "alpha beta gamma delta" })
    vim.cmd("MentorChatAsk how do I structure this module?")
    wait_until(function()
      return chat.active_count() == 0
    end)
    local text = chat_text()
    H.contains_text(text, "> how do I structure this module?", "user line recorded")
    H.contains_text(text, "alpha beta gamma delta", "full response streamed")
    H.contains_text(text, "[fake provider,", "usage note")
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
      return chat.active_count() == 0
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

  H.test("a second interactive request is refused while one runs", function()
    configure("guard")
    edit_git_project("guardproj")
    fake.chunk_delay_ms = 20
    vim.cmd("MentorChat")
    fake.script({ "one two three four five" })
    local ok = chat.ask("first question")
    H.ok(ok, "first ask accepted")
    local ok2, err = chat.ask("second question")
    H.ok(not ok2, "second ask refused")
    H.contains_text(err, "already running", "actionable refusal")
    vim.cmd("MentorStop")
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
end
