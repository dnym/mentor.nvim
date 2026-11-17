-- Persistent linear Coach conversation (MVP: one per project). The transcript
-- lives in storage: opening Coach renders it, requests extend it, and it
-- resumes intact after a restart. The buffer is just a view — streaming
-- appends arrive asynchronously and are dropped if the operation was
-- cancelled or its buffer/project binding no longer holds. Only one
-- interactive operation runs per instance; additional explicit requests
-- queue automatically in order.

local project = require("mentor.project")
local config = require("mentor.config")
local records = require("mentor.storage.records")
local sanitize = require("mentor.sanitize")
local prompts = require("mentor.prompts")
local memory_mod = require("mentor.memory")
local tools_mod = require("mentor.tools")
local scratch = require("mentor.ui.scratch")
local mdtable = require("mentor.ui.mdtable")

local M = {}

local chat_buffers = {} -- project identity -> bufnr
local ops = {} -- bufnr -> active operation
local active_op = nil -- the single running interactive operation
local ask_queue = {} -- pending {buf, identity, text} in FIFO order

local function chat_name(identity)
  return "mentor://coach/" .. identity:gsub("^/+", "")
end

local function header_lines()
  local cfg = config.get()
  local status
  if cfg.dev.fake_provider then
    status = "offline fake provider (dev.fake_provider)"
  else
    status = require("mentor.provider").describe("coach")
  end
  -- Markdown-friendly so it renders cleanly alongside the transcript.
  return {
    "# Mentor Coach",
    "- Transcript persists across restarts.",
    "- Edit a line starting with `> ` and press `<CR>` on it to send; `:MentorChatAsk <text>` also works.",
    "- `:MentorStop` cancels the running request; further requests queue automatically.",
    "- Provider: " .. status,
    "",
  }
end

-- Header rows are never sent by <CR>; the header always has this length.
local HEADER_ROWS = 6

local note_ns = vim.api.nvim_create_namespace("mentor_chat_notes")
-- Marks the user lines the plugin itself rendered, so <CR> can tell a
-- transcript line (re-send: keep it) from a typed draft (consumed on send).
local sent_ns = vim.api.nvim_create_namespace("mentor_chat_sent")
local sent_text = {} -- bufnr -> extmark id -> rendered line text

---@param buf integer
---@param first integer 0-based row of the first rendered user line
---@param lines string[]
local function mark_sent(buf, first, lines)
  sent_text[buf] = sent_text[buf] or {}
  for i, line in ipairs(lines) do
    local id = vim.api.nvim_buf_set_extmark(buf, sent_ns, first + i - 1, 0, { invalidate = true })
    sent_text[buf][id] = line
  end
end

---The rendered text of the transcript user line at `row` (0-based), or nil
---when the line is a draft the user typed.
local function sent_line_at(buf, row)
  local marks = vim.api.nvim_buf_get_extmarks(buf, sent_ns, { row, 0 }, { row, -1 }, { details = true })
  for _, mark in ipairs(marks) do
    if not mark[4].invalid then
      return (sent_text[buf] or {})[mark[1]]
    end
  end
  return nil
end
local markdown_ready = false

---One-time Markdown wiring for chat buffers: the bundled treesitter markdown
---parser serves the `mentorchat` filetype (so third-party Markdown renderers
---can attach to it by filetype), and plugin annotation lines (tool activity,
---status notes) get their own highlight on top of the Markdown highlighting.
local function ensure_markdown()
  if markdown_ready then
    return
  end
  markdown_ready = true
  pcall(vim.treesitter.language.register, "markdown", "mentorchat")
  vim.api.nvim_set_hl(0, "MentorChatNote", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "MentorChatError", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_decoration_provider(note_ns, {
    on_win = function(_, _, buf)
      return vim.bo[buf].filetype == "mentorchat"
    end,
    on_line = function(_, _, buf, row)
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      if not line or line == "" then
        return
      end
      local group
      if line:sub(1, #"⌁ error:") == "⌁ error:" then
        group = "MentorChatError"
      elseif line:sub(1, #"⌁ ") == "⌁ " then
        group = "MentorChatNote"
      end
      if group then
        vim.api.nvim_buf_set_extmark(buf, note_ns, row, 0, {
          end_row = row,
          end_col = #line,
          hl_group = group,
          ephemeral = true,
          priority = 200,
        })
      end
    end,
  })
end

---Markdown display options for a window showing a chat buffer.
local function apply_window_options(win)
  if not config.get().chat.markdown or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local wo = vim.wo[win][0]
  wo.conceallevel = 2
  wo.linebreak = true
end

---Sanitized storage scope for a project identity.
local function project_row_id(proj)
  return records.projects.touch({
    identity = proj.identity,
    root = proj.root,
    is_git = proj.is_git,
    git_common_dir = proj.git_common_dir,
  })
end

---Aligns Markdown tables in reply text (display only; storage keeps the
---model's text). Widths follow concealed rendering when Markdown is on.
---@param lines string[]
---@return string[] lines, boolean changed
local function align_tables(lines)
  local cfg = config.get().chat
  if not cfg.align_tables then
    return lines, false
  end
  return mdtable.align(lines, { conceal = cfg.markdown })
end

local function append_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local last = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  vim.api.nvim_buf_set_lines(buf, #last, #last, false, lines)
end

---Render one persisted transcript row into display lines.
---@param row table
---@param tool_names table<string, string> call id -> tool name
local function render_row(row, tool_names)
  if row.role == "user" then
    local out = {}
    for _, line in ipairs(vim.split(row.content, "\n", { plain = true })) do
      out[#out + 1] = "> " .. line
    end
    return out
  end
  if row.role == "assistant" then
    local out = align_tables(vim.split(row.content, "\n", { plain = true }))
    local calls = row.tool_calls and (pcall(vim.json.decode, row.tool_calls))
    if type(calls) == "table" then
      for _, call in ipairs(calls) do
        tool_names[call.id] = call.name
        out[#out + 1] = "⌁ called " .. call.name
      end
    end
    return out
  end
  if row.role == "tool" then
    local name = row.tool or tool_names[row.tool_call_id] or "tool"
    local note = "⌁ " .. name .. " result"
    if row.source and row.source:sub(1, 13) ~= "mentor-paths:" then
      note = note .. " (" .. row.source .. ")"
    end
    return { note }
  end
  return {}
end

---Rebuild provider-format history from persisted rows, repairing any turn
---that was interrupted before its tool results were stored, and
---re-authorizing persisted memory results against the current policy.
---@param rows table[]
---@param proj mentor.Project
---@return table[]
local function replay_messages(rows, proj)
  local out = {}
  for _, row in ipairs(rows) do
    if row.role == "user" then
      out[#out + 1] = { role = "user", content = row.content }
    elseif row.role == "assistant" then
      local m = { role = "assistant", content = row.content or "" }
      if row.tool_calls then
        local ok, calls = pcall(vim.json.decode, row.tool_calls)
        if ok and type(calls) == "table" and #calls > 0 then
          m.tool_calls = {}
          for _, call in ipairs(calls) do
            m.tool_calls[#m.tool_calls + 1] = {
              id = call.id,
              type = "function",
              ["function"] = { name = call.name, arguments = vim.json.encode(call.arguments or {}) },
            }
          end
        end
      end
      out[#out + 1] = m
    elseif row.role == "tool" then
      local content = row.content
      if row.tool and row.tool:find("^memory_") then
        content = memory_mod.reauthorize_result(content, proj)
      end
      out[#out + 1] = {
        role = "tool",
        tool_call_id = row.tool_call_id,
        content = content,
        source = row.source,
        tool = row.tool,
      }
    end
  end
  return M._pair_tool_messages(out)
end

---Providers require every assistant tool call to be answered by a tool
---message directly after it, and every tool message to answer a call of the
---assistant turn it follows. An operation stopped mid-batch (tool-call
---limit, deadline, cancellation) or a crash leaves unanswered calls: keep
---only the answered calls, and drop tool messages that answer nothing.
---@param messages table[]
---@return table[]
function M._pair_tool_messages(messages)
  local out = {}
  local i = 1
  while i <= #messages do
    local m = messages[i]
    if m.role == "assistant" and m.tool_calls then
      local results, answered = {}, {}
      local j = i + 1
      while j <= #messages and messages[j].role == "tool" do
        results[#results + 1] = messages[j]
        answered[messages[j].tool_call_id or ""] = true
        j = j + 1
      end
      local kept, kept_ids = {}, {}
      for _, call in ipairs(m.tool_calls) do
        if call.id and answered[call.id] and not kept_ids[call.id] then
          kept[#kept + 1] = call
          kept_ids[call.id] = true
        end
      end
      local copy = vim.tbl_extend("force", {}, m)
      copy.tool_calls = #kept > 0 and kept or nil
      out[#out + 1] = copy
      if copy.tool_calls then
        for _, result in ipairs(results) do
          if kept_ids[result.tool_call_id] then
            out[#out + 1] = result
            kept_ids[result.tool_call_id] = nil -- one result per call
          end
        end
      end
      i = j
    elseif m.role == "tool" then
      i = i + 1 -- orphan: no assistant tool call precedes it
    else
      out[#out + 1] = m
      i = i + 1
    end
  end
  return out
end

local function estimate_messages(messages)
  local bytes = 0
  for _, m in ipairs(messages) do
    bytes = bytes + #(m.content or "")
    if m.tool_calls then
      bytes = bytes + #vim.json.encode(m.tool_calls)
    end
  end
  return math.ceil(bytes / 4) + 64 * #messages
end

---Trim history oldest-first to the configured conversation budget. Cuts
---only land on user messages, so an assistant tool-call turn is never
---separated from its tool results.
---@param system string
---@param history table[]
---@return table[] messages ready for the provider
function M._build_request_messages(system, history)
  local cap = config.get().chat.history_max_tokens
  local starts = {}
  for i, m in ipairs(history) do
    if m.role == "user" then
      starts[#starts + 1] = i
    end
  end
  local function fits(start)
    local combined = { { role = "system", content = system } }
    for i = start, #history do
      combined[#combined + 1] = history[i]
    end
    return estimate_messages(combined) <= cap
  end
  -- Always keep at least the newest turn (the last user message onward).
  local first = starts[#starts] or 1
  for _, start in ipairs(starts) do
    if fits(start) then
      first = start
      break
    end
  end
  local messages = { { role = "system", content = system } }
  for i = first, #history do
    messages[#messages + 1] = history[i]
  end
  return messages
end
local build_request_messages = M._build_request_messages

---The chat buffer for a project, created when missing (rendering any
---persisted transcript) and kept bound to its originating project.
---@param proj mentor.Project
function M.buffer_for(proj)
  local existing = chat_buffers[proj.identity]
  if scratch.usable(existing) and vim.b[existing].mentor_project == proj.identity then
    return existing
  end
  local name = chat_name(proj.identity)
  local buf = scratch.find(name)
  local fresh = buf == nil
  if fresh then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = true
  vim.b[buf].mentor_project = proj.identity
  vim.bo[buf].filetype = "mentorchat"
  if config.get().chat.markdown then
    ensure_markdown()
    if not pcall(vim.treesitter.start, buf, "markdown") then
      vim.bo[buf].syntax = "markdown"
    end
  end

  if fresh then
    local lines = header_lines()
    local rows = records.conversations.load(project_row_id(proj), "coach")
    local tool_names = {}
    local user_spans = {}
    for _, row in ipairs(rows) do
      local rendered = render_row(row, tool_names)
      if row.role == "user" then
        user_spans[#user_spans + 1] = { #lines, rendered }
      end
      for _, line in ipairs(rendered) do
        lines[#lines + 1] = line
      end
      lines[#lines + 1] = ""
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, sent_ns, 0, -1)
    sent_text[buf] = {}
    for _, span in ipairs(user_spans) do
      mark_sent(buf, span[1], span[2])
    end
  end

  vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
    noremap = true,
    callback = function()
      local line = vim.api.nvim_get_current_line()
      local text = line:gsub("^>%s*", "")
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if text == "" or row <= HEADER_ROWS or line:match("^#") then
        return
      end
      local cur = vim.api.nvim_get_current_buf()
      local rendered = sent_line_at(cur, row - 1)
      local ok, err = M.ask(text)
      if not ok then
        vim.notify(err, vim.log.levels.WARN)
        return
      end
      -- ask() appends the message to the transcript; consume the typed draft
      -- (or undo the edit of an earlier line) so it does not appear twice.
      if vim.api.nvim_buf_is_valid(cur) then
        local now = vim.api.nvim_buf_get_lines(cur, row - 1, row, false)[1]
        if now == line then
          local replacement = rendered and rendered ~= line and { rendered } or (not rendered and {} or nil)
          if replacement then
            vim.api.nvim_buf_set_lines(cur, row - 1, row, false, replacement)
          end
        end
      end
    end,
  })
  -- The buffer may be a recycled hidden one; clear stale handlers first.
  vim.api.nvim_clear_autocmds({ buffer = buf, group = "mentor" })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    group = "mentor",
    callback = function()
      apply_window_options(vim.api.nvim_get_current_win())
    end,
  })
  vim.api.nvim_create_autocmd({ "bufwipeout" }, {
    buffer = buf,
    group = "mentor",
    callback = function()
      sent_text[buf] = nil
      for i = #ask_queue, 1, -1 do
        if ask_queue[i].buf == buf then
          table.remove(ask_queue, i)
        end
      end
      local op = ops[buf]
      if op then
        op.cancelled = true
        if op.handle then
          op.handle:cancel()
        end
      end
      ops[buf] = nil
      if chat_buffers[proj.identity] == buf then
        chat_buffers[proj.identity] = nil
      end
    end,
  })
  scratch.wipe_on_unload(buf, "mentor")
  chat_buffers[proj.identity] = buf
  return buf
end

---Opens (or focuses) the Coach window for the current project.
---@return integer|nil bufnr, string|nil actionable error
function M.open()
  if not config.is_valid() then
    return nil, "mentor.nvim: configuration is invalid; run :checkhealth mentor"
  end
  local proj = project.ensure_current()
  if not proj then
    return nil,
      "mentor.nvim: no project context; open a file inside a project or configure projects.fallback_root"
  end
  local buf = M.buffer_for(proj)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    vim.cmd("vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  apply_window_options(win)
  return buf
end

---Appends streamed text to the active response line, splitting newlines.
local function append_delta(buf, op, chunk)
  if op.cancelled or not vim.api.nvim_buf_is_valid(buf) or ops[buf] ~= op then
    return
  end
  local parts = vim.split(chunk, "\n", { plain = true })
  local current = vim.api.nvim_buf_get_lines(buf, op.line_idx, op.line_idx + 1, false)[1] or ""
  local replacement = { current .. parts[1] }
  for i = 2, #parts do
    replacement[#replacement + 1] = parts[i]
  end
  vim.api.nvim_buf_set_lines(buf, op.line_idx, op.line_idx + 1, false, replacement)
  op.line_idx = op.line_idx + #replacement - 1
end

---Insert a note line at the current write position (tool activity, notices).
local function insert_note(buf, op, text)
  if op.cancelled or not vim.api.nvim_buf_is_valid(buf) or ops[buf] ~= op then
    return
  end
  local current = vim.api.nvim_buf_get_lines(buf, op.line_idx, op.line_idx + 1, false)[1] or ""
  local parts = vim.split(text, "\n", { plain = true })
  local block = {}
  if current ~= "" then
    block[#block + 1] = current
  end
  for _, p in ipairs(parts) do
    block[#block + 1] = p
  end
  block[#block + 1] = ""
  vim.api.nvim_buf_set_lines(buf, op.line_idx, op.line_idx + 1, false, block)
  op.line_idx = op.line_idx + #block - 1
end

local function pump_queue()
  if active_op then
    return
  end
  local item = table.remove(ask_queue, 1)
  if not item then
    return
  end
  if not vim.api.nvim_buf_is_valid(item.buf) then
    return pump_queue()
  end
  local proj = project.for_dir(item.identity)
  if not proj or proj.identity ~= item.identity then
    return pump_queue()
  end

  local buf = item.buf
  -- Locate the blank line under this ask's user line (line indices shift
  -- while earlier operations stream, so resolve it at pump time).
  local view = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local marker = "> " .. item.text
  local stream_at = #view
  for i = #view, 1, -1 do
    if view[i] == marker then
      stream_at = i
      break
    end
  end
  -- The queued placeholder has served its purpose once the request runs.
  if view[stream_at + 1] == "⌁ queued" then
    vim.api.nvim_buf_set_lines(buf, stream_at, stream_at + 1, false, {})
  end
  -- A blank separator keeps the reply out of the user's "> " quote (Markdown
  -- would otherwise continue the block quote lazily), then stream into an
  -- empty line below it.
  local next_line = vim.api.nvim_buf_get_lines(buf, stream_at, stream_at + 1, false)[1]
  if next_line == "" then
    vim.api.nvim_buf_set_lines(buf, stream_at, stream_at, false, { "" })
  else
    vim.api.nvim_buf_set_lines(buf, stream_at, stream_at, false, { "", "" })
  end
  stream_at = stream_at + 1
  local op =
    { start_idx = stream_at, line_idx = stream_at, cancelled = false, handle = nil, project = item.identity }
  ops[buf] = op
  active_op = op

  local row_id = project_row_id(proj)
  local rows = records.conversations.load(row_id, "coach")
  local history = replay_messages(rows, proj)
  local system = prompts.coach_system(proj)
  local mem_block = memory_mod.render_context(proj)
  if mem_block ~= "" then
    system = system .. "\n\n" .. mem_block
  end
  local messages = build_request_messages(system, history)

  local function note(text)
    insert_note(buf, op, text)
  end

  -- Interactive work preempts automatic background work (observations and
  -- consolidation share the provider endpoint); pending jobs resume after.
  require("mentor.observer").preempt()

  local handle, run_err = require("mentor.agent").run({
    mode = "coach",
    project = proj,
    messages = messages,
    -- Explicit allow-list: Coach gets investigation and memory only. The
    -- implement group must never reach Coach (or Observer) — edits require
    -- an explicit :MentorImplement command with a developer-captured target.
    tools = tools_mod.names({ "investigation", "memory" }),
    on_delta = function(chunk)
      append_delta(buf, op, chunk)
    end,
    on_tool = function(phase, call)
      if phase ~= "done" then
        return
      end
      local line = "⌁ " .. call.name
      if call.arguments and call.arguments.path then
        line = line .. " " .. call.arguments.path
      end
      note(line)
    end,
    on_note = function(text)
      note("⌁ " .. text)
    end,
    on_message = function(msg)
      -- The provider already saw it unsanitized; storage and the buffer view
      -- keep the sanitized copy so pasted credentials never persist.
      local clean = vim.deepcopy(msg)
      clean.content = sanitize.sanitize(msg.content or "")
      records.conversations.append(row_id, "coach", clean)
    end,
    on_done = function(err, info)
      active_op = nil
      -- Tables are aligned once the reply is complete: while streaming, rows
      -- arrive piecemeal and column widths are not yet known. Alignment
      -- never changes the line count, so recorded positions stay valid.
      if ops[buf] == op and vim.api.nvim_buf_is_valid(buf) then
        local reply = vim.api.nvim_buf_get_lines(buf, op.start_idx, op.line_idx + 1, false)
        local aligned, changed = align_tables(reply)
        if changed then
          vim.api.nvim_buf_set_lines(buf, op.start_idx, op.start_idx + #reply, false, aligned)
        end
      end
      if not op.cancelled and vim.api.nvim_buf_is_valid(buf) then
        if err == "cancelled" then
          note("⌁ cancelled")
        elseif err then
          note("⌁ error: " .. ((info and info.message) or err))
        elseif info and info.stop_reason and info.stop_reason ~= "stop" then
          note("⌁ stopped: " .. info.stop_reason)
        end
        if info and info.usage and info.usage.model_requests and info.usage.model_requests > 0 then
          local u = info.usage
          local reported = u.reported_input + u.reported_output
          local note_text = string.format(
            "⌁ %d model request(s), %d tool call(s), ~%d est tokens",
            u.model_requests,
            u.tool_calls,
            u.estimated_tokens
          )
          if reported > 0 then
            note_text = note_text
              .. string.format(", provider reported %d/%d", u.reported_input, u.reported_output)
          end
          note(note_text)
        end
        if vim.api.nvim_buf_is_valid(buf) then
          append_lines(buf, { "" })
        end
      end
      if ops[buf] == op then
        ops[buf] = nil
      end
      pump_queue()
    end,
  })

  if not handle then
    active_op = nil
    if ops[buf] == op then
      ops[buf] = nil
    end
    if vim.api.nvim_buf_is_valid(buf) then
      append_lines(buf, { "⌁ error: " .. tostring(run_err), "" })
    end
    return
  end
  op.handle = handle
end

---Sends one interactive Coach request bound to the chat buffer's project.
---Additional requests while one is running queue automatically.
---@param text string
---@return boolean ok, string|nil actionable error
function M.ask(text)
  text = vim.trim(type(text) == "string" and text or "")
  if text == "" then
    return false, "mentor.nvim: empty request"
  end
  if not config.is_valid() then
    return false, "mentor.nvim: configuration is invalid; run :checkhealth mentor"
  end
  local missing = require("mentor.provider").missing("coach")
  if missing then
    return false, missing
  end
  -- Prefer the chat buffer when the caller is already in one; otherwise open.
  local buf = vim.api.nvim_win_get_buf(0)
  if not vim.api.nvim_buf_get_name(buf):find("^mentor://coach/") or not vim.b[buf].mentor_project then
    local err
    buf, err = M.open()
    if not buf then
      return false, err
    end
  end

  local identity = vim.b[buf].mentor_project
  local proj = project.for_dir(identity)
  if not proj or proj.identity ~= identity then
    return false, "mentor.nvim: the chat buffer's project is no longer resolvable; reopen Coach"
  end

  -- Sanitize before anything is stored or sent: user text may paste secrets.
  local clean = sanitize.sanitize(text)

  records.conversations.append(project_row_id(proj), "coach", { role = "user", content = clean })

  local queued = active_op ~= nil
  local last = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start = #last
  local user_lines = render_row({ role = "user", content = clean }, {})
  local written = vim.list_extend(vim.list_extend({}, user_lines), { "" })
  vim.api.nvim_buf_set_lines(buf, start, start, false, written)
  mark_sent(buf, start, user_lines)
  if queued then
    vim.api.nvim_buf_set_lines(buf, start + #user_lines, start + #user_lines, false, { "⌁ queued" })
  end

  ask_queue[#ask_queue + 1] = {
    buf = buf,
    identity = identity,
    text = clean,
    start_line = start + #user_lines + (queued and 1 or 0),
  }
  pump_queue()
  return true
end

---Cancels the running Coach operation (queued requests keep their place).
---Returns the number cancelled.
function M.stop()
  local n = 0
  for _, op in pairs(ops) do
    if op.handle and op.handle:is_active() then
      op.cancelled = true
      op.handle:cancel()
      n = n + 1
    end
  end
  return n
end

---Explicitly clears the stored Coach transcript for a project (independent
---of memory erasure: chat material is cleared only through this path).
---Cancels operations bound to that project's chat buffer first.
---@param proj mentor.Project
---@return integer removed
function M.clear(proj)
  local buf = chat_buffers[proj.identity]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    local op = ops[buf]
    if op then
      op.cancelled = true
      if op.handle then
        op.handle:cancel()
      end
      ops[buf] = nil
    end
    for i = #ask_queue, 1, -1 do
      if ask_queue[i].buf == buf then
        table.remove(ask_queue, i)
      end
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, header_lines())
  end
  return records.conversations.delete_all(project_row_id(proj), "coach")
end

---Active operation count (status display).
function M.active_count()
  local n = 0
  for _, op in pairs(ops) do
    if op.handle and op.handle:is_active() then
      n = n + 1
    end
  end
  return n
end

---Queued request count (status display).
function M.queued_count()
  return #ask_queue
end

function M.reset()
  for _, op in pairs(ops) do
    if op.handle then
      op.cancelled = true
      op.handle:cancel()
    end
  end
  ops = {}
  ask_queue = {}
  active_op = nil
  chat_buffers = {}
  sent_text = {}
end

return M
