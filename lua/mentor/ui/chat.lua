-- Persistent linear Coach conversation (MVP: one per project). Native scratch
-- buffer; streaming appends arrive asynchronously and are dropped if the
-- operation was cancelled or its buffer/project binding no longer holds.

local project = require("mentor.project")

local M = {}

local chat_buffers = {} -- project identity -> bufnr
local ops = {} -- bufnr -> active operation

M.provider = nil -- injectable for tests; defaults to fake in dev mode

local function chat_name(identity)
  return "mentor://coach/" .. identity:gsub("^/+", "")
end

local HEADER = {
  "# Mentor Coach (Milestone 1 shell)",
  "# Edit a line starting with '> ', press <CR> on it to send; :MentorChatAsk <text> also works.",
  "# :MentorStop cancels a running request. Responses stream below.",
  "",
}

---The chat buffer for a project, created when missing. The buffer keeps its
---originating project binding so focus changes cannot retarget it.
---@param proj mentor.Project
function M.buffer_for(proj)
  local existing = chat_buffers[proj.identity]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    return existing
  end
  local name = chat_name(proj.identity)
  local buf = vim.fn.bufnr(name)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, HEADER)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = true
  vim.b[buf].mentor_project = proj.identity
  vim.bo[buf].filetype = "mentorchat"

  vim.api.nvim_buf_set_keymap(buf, "n", "<CR>", "", {
    noremap = true,
    callback = function()
      local line = vim.api.nvim_get_current_line()
      local text = line:gsub("^>%s*", "")
      if text ~= "" and not line:match("^#") then
        M.ask(text)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "bufwipeout" }, {
    buffer = buf,
    group = "mentor",
    callback = function()
      local op = ops[buf]
      if op and op.handle then
        op.cancelled = true
        op.handle:cancel()
      end
      ops[buf] = nil
      chat_buffers[proj.identity] = nil
    end,
  })
  chat_buffers[proj.identity] = buf
  return buf
end

---Opens (or focuses) the Coach window for the current project.
---@return integer|nil bufnr, string|nil actionable error
function M.open()
  local cfg = require("mentor.config")
  if not cfg.is_valid() then
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

local function finish(buf, op, info)
  if not op.cancelled and vim.api.nvim_buf_is_valid(buf) then
    if info and info.ok and info.estimated_tokens then
      local note = string.format("\n[fake provider, ~%d estimated tokens]", info.estimated_tokens)
      local parts = vim.split(note, "\n", { plain = true })
      local current = vim.api.nvim_buf_get_lines(buf, op.line_idx, op.line_idx + 1, false)[1] or ""
      local replacement = { current .. parts[1] }
      for i = 2, #parts do
        replacement[#replacement + 1] = parts[i]
      end
      vim.api.nvim_buf_set_lines(buf, op.line_idx, op.line_idx + 1, false, replacement)
      op.line_idx = op.line_idx + #replacement - 1
    end
    vim.api.nvim_buf_set_lines(buf, op.line_idx, op.line_idx, false, { "" })
    op.line_idx = op.line_idx + 1
  end
  if ops[buf] == op then
    ops[buf] = nil
  end
end

---Sends one interactive Coach request bound to the chat buffer's project.
---@param text string
---@return boolean ok, string|nil actionable error
function M.ask(text)
  text = vim.trim(type(text) == "string" and text or "")
  if text == "" then
    return false, "mentor.nvim: empty request"
  end
  local cfg = require("mentor.config")
  if not cfg.is_valid() then
    return false, "mentor.nvim: configuration is invalid; run :checkhealth mentor"
  end
  -- Prefer the chat buffer when the caller is already in one; otherwise open.
  local buf = vim.api.nvim_win_get_buf(0)
  if not vim.api.nvim_buf_get_name(buf):find("^mentor://coach/") then
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

  if ops[buf] then
    return false, "mentor.nvim: a Coach request is already running; :MentorStop cancels it"
  end

  local provider ---@type table
  if cfg.get().dev.fake_provider then
    provider = require("mentor.provider.fake")
  else
    local provider_mod = require("mentor.provider")
    local missing = provider_mod.missing("coach")
    if missing then
      return false, missing
    end
    return false,
      "mentor.nvim: the OpenAI-compatible request loop lands in Milestone 3; set dev.fake_provider = true to exercise Coach offline meanwhile"
  end
  if M.provider then
    provider = M.provider
  end

  -- One interactive operation per instance; refuse politely.
  for _, op in pairs(ops) do
    if op ~= ops[buf] and op.handle and op.handle:is_active() then
      return false, "mentor.nvim: an interactive operation is already running; :MentorStop cancels it"
    end
  end

  local last = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local start = #last
  vim.api.nvim_buf_set_lines(buf, start, start, false, { "> " .. text, "", "" })
  local op = { line_idx = start + 2, cancelled = false, handle = nil, project = identity }
  ops[buf] = op

  op.handle = provider.request({
    text = text,
    on_delta = function(chunk)
      append_delta(buf, op, chunk)
    end,
    on_done = function(info)
      finish(buf, op, info)
    end,
  })
  return true
end

---Cancels active Coach operations. Returns the number cancelled.
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

function M.reset()
  for _, op in pairs(ops) do
    if op.handle then
      op.cancelled = true
      op.handle:cancel()
    end
  end
  ops = {}
  chat_buffers = {}
end

return M
