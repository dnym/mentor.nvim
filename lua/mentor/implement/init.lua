-- Implement mode: one explicit command, one fixed target, one proposal.
--
-- The developer selects a characterwise/linewise range or an insertion point
-- in a single writable project buffer via :MentorImplement. The captured
-- target (buffer, version, range, path, policy state) is frozen before the
-- model ever runs; the model can only submit replacement text through the
-- propose_edit tool, which records an in-memory proposal. Nothing touches
-- the buffer until the developer explicitly accepts, and acceptance
-- revalidates everything. Proposals are ephemeral: restarting Neovim
-- discards them. No file is ever written and generated code is never run.
--
-- Presentation: a run opens nothing. It reports through notifications
-- (started, proposal ready, stopped/failed) and narrates into one reusable
-- Markdown log per project (:MentorImplementLog). A proposal is reviewed on
-- request (:MentorImplementReview) in its own tab page: the whole file
-- before and after, in native diff mode, with the log below. Accepting or
-- rejecting closes that tab and returns to the window it was opened from;
-- the developer's own layout is never rearranged.

local agent = require("mentor.agent")
local config = require("mentor.config")
local policy_mod = require("mentor.policy")
local project_mod = require("mentor.project")
local prompts = require("mentor.prompts")
local tools_mod = require("mentor.tools")

local scratch = require("mentor.ui.scratch")
local M = {}

local BLOCKWISE_MSG = "mentor.nvim: blockwise selections are not supported yet; "
  .. "use a characterwise or linewise selection, or an insertion point"

-- Active runs by project row id; proposals are ordered for "latest" lookup.
---@type table<integer, table>
local sessions = {}
---@type table<integer, table>
local proposals = {}
local proposal_order = {}
local next_proposal_id = 1

-- ---------------------------------------------------------------------------
-- Target capture and range conversion (defined once, here)
-- ---------------------------------------------------------------------------

---Byte length of the UTF-8 character starting at 0-based byte index `byte`
---in `line`; 0 when the index is past the end.
local function char_width_at(line, byte)
  if byte < 0 or byte >= #line then
    return 0
  end
  local byteindex = vim.str_utfindex(line, byte)
  local next_byte = vim.str_byteindex(line, byteindex + 1)
  return next_byte - byte
end

---Characterwise visual marks -> 0-based end-exclusive buffer coordinates.
---'> marks the START of the last selected character, so the exclusive end
---must extend past its UTF-8 width (multibyte-safe by construction).
---@param buf integer
---@param srow, scol, erow, ecol integer 1-based mark line/byte-column
---@return table|nil range {row1, col1, row2, col2}
function M._charwise_range(buf, srow, scol, erow, ecol)
  if srow < 1 or erow < srow or scol < 1 or (srow == erow and ecol < scol) then
    return nil
  end
  local nlines = vim.api.nvim_buf_line_count(buf)
  if erow > nlines then
    return nil
  end
  local last_line = vim.api.nvim_buf_get_lines(buf, erow - 1, erow, false)[1] or ""
  local end_col = (ecol - 1) + char_width_at(last_line, ecol - 1)
  return { row1 = srow - 1, col1 = scol - 1, row2 = erow - 1, col2 = end_col }
end

---Linewise inclusive lines -> 0-based range covering whole lines.
---Mid-buffer the end lands on the next line's start (materialized EOL).
---When the range reaches the last line there is no trailing EOL to cover,
---so the end sits at the end of that line's text; intake then normalizes a
---trailing newline in the replacement to keep the line count stable.
---@param buf integer
---@return table|nil range {row1, col1, row2, col2, eof}
function M._linewise_range(buf, line1, line2)
  if line1 < 1 or line2 < line1 then
    return nil
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if line2 > count then
    return nil
  end
  if line2 < count then
    return { row1 = line1 - 1, col1 = 0, row2 = line2, col2 = 0, eof = false }
  end
  local last_line = vim.api.nvim_buf_get_lines(buf, count - 1, count, false)[1] or ""
  return { row1 = line1 - 1, col1 = 0, row2 = count - 1, col2 = #last_line, eof = true }
end

---Freeze the command's target: buffer, exact range, current version, path,
---and policy verdict. Later steps only ever compare against this snapshot.
---@param proj mentor.Project
---@param req table { range, line1, line2, vmode } as passed by the command
---@return table|nil target
---@return string|nil err
function M._capture_target(proj, req)
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil, "mentor.nvim: Implement needs a buffer backed by a real file path"
  end
  if not vim.bo[buf].modifiable then
    return nil, "mentor.nvim: the target buffer is not modifiable"
  end

  -- Decide the selection kind. A range only counts as a live visual
  -- selection when it matches the current window's marks; otherwise an
  -- explicit numeric range behaves linewise. Stale modes from earlier
  -- selections never apply.
  local marks_live = req.range == 1
    and req.vmode ~= ""
    and vim.fn.line("'<") == req.line1
    and vim.fn.line("'>") == req.line2
    and vim.fn.getpos("'<")[1] == 0
    and vim.fn.getpos("'>")[1] == 0
  if marks_live and req.vmode == "\022" then
    return nil, BLOCKWISE_MSG
  end

  local mode, range
  if req.range == 0 then
    mode = "point"
    -- nvim_win_get_cursor rows are 1-based; ranges here are 0-based. Clamp
    -- anyway: a stale cursor (e.g. restored from shada) can sit past the
    -- last line.
    local cur = vim.api.nvim_win_get_cursor(0)
    local nlines = vim.api.nvim_buf_line_count(buf)
    local row = math.max(0, math.min(cur[1] - 1, nlines - 1))
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local col = math.max(0, math.min(cur[2], #line))
    range = { row1 = row, col1 = col, row2 = row, col2 = col }
  elseif marks_live and req.vmode == "v" then
    mode = "charwise"
    local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    range = M._charwise_range(buf, s[2], s[3], e[2], e[3])
    if not range then
      return nil, "mentor.nvim: the selection is invalid for this buffer"
    end
  else
    mode = "linewise"
    range = M._linewise_range(buf, req.line1, req.line2)
    if not range then
      return nil, "mentor.nvim: invalid range for Implement"
    end
  end

  local bufpath = vim.fn.fnamemodify(name, ":p")
  local pol = policy_mod.for_project(proj)
  local _, denied = pol:authorize(bufpath)
  if denied then
    return nil, "mentor.nvim: the target is off-limits: " .. denied
  end

  local text =
    table.concat(vim.api.nvim_buf_get_text(buf, range.row1, range.col1, range.row2, range.col2, {}), "\n")
  local max_bytes = config.get().implement.max_target_bytes
  if max_bytes > 0 and #text > max_bytes then
    return nil,
      string.format(
        "mentor.nvim: the selection is %d bytes; the Implement target cap is %d bytes",
        #text,
        max_bytes
      )
  end

  return {
    buf = buf,
    bufname = name,
    bufpath = bufpath,
    mode = mode,
    range = range,
    text = text,
    changedtick = vim.api.nvim_buf_get_var(buf, "changedtick"),
    filetype = vim.bo[buf].filetype,
    project = proj,
  }
end

local function describe_target(target)
  if target.mode == "point" then
    return string.format(
      "insertion point at line %d, column %d of %s",
      target.range.row1 + 1,
      target.range.col1 + 1,
      target.bufname
    )
  end
  -- A linewise range normally ends at the start of the line after it; one
  -- reaching the end of the buffer ends inside its last line instead.
  local last_line = (target.mode == "linewise" and not target.range.eof) and target.range.row2
    or target.range.row2 + 1
  return string.format(
    "%s selection covering lines %d-%d (%d bytes) of %s",
    target.mode,
    target.range.row1 + 1,
    last_line,
    #target.text,
    target.bufname
  )
end

M._describe_target = describe_target

-- ---------------------------------------------------------------------------
-- Proposal registry
-- ---------------------------------------------------------------------------

local function preview_name(id, which)
  return "mentor://implement/" .. id .. "/" .. which
end

local function notify(msg, level)
  vim.notify("mentor.nvim: " .. msg, level or vim.log.levels.INFO)
end

---Lines of text, counting a final unterminated line and not an empty
---remainder after a trailing newline.
local function line_count(text)
  if text == "" then
    return 0
  end
  local _, breaks = text:gsub("\n", "")
  return breaks + (text:sub(-1) == "\n" and 0 or 1)
end

---Error text as carried inside a sentence (no repeated plugin prefix).
local function bare(msg)
  return (tostring(msg):gsub("^mentor%.nvim: ", ""))
end

local function short_target(target)
  local name = vim.fn.fnamemodify(target.bufname, ":t")
  if target.mode == "point" then
    return string.format("line %d of %s", target.range.row1 + 1, name)
  end
  local last_line = (target.mode == "linewise" and not target.range.eof) and target.range.row2
    or target.range.row2 + 1
  if last_line == target.range.row1 + 1 then
    return string.format("line %d of %s", last_line, name)
  end
  return string.format("lines %d-%d of %s", target.range.row1 + 1, last_line, name)
end

-- ---------------------------------------------------------------------------
-- Run log: one reusable Markdown buffer per project, shown only on request
-- ---------------------------------------------------------------------------

local function log_name(proj)
  return "mentor://implement-run/" .. proj.identity
end

---The project's log buffer, created on first use and reused afterwards.
---@param proj mentor.Project
---@return integer buf
local function log_buffer(proj)
  local name = log_name(proj)
  local buf = scratch.find(name)
  if buf then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].mentor_project = proj.identity
  -- Plugin annotations (⌁ lines) get the same note highlight as in Coach.
  vim.b[buf].mentor_notes = true
  require("mentor.ui.chat").ensure_note_highlights()
  vim.bo[buf].filetype = "markdown"
  scratch.wipe_on_unload(buf, "mentor")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# Mentor Implement log",
    "",
    "- One section per run in this session; proposals are not kept across restarts.",
    "- `:MentorImplementReview` opens the newest pending proposal.",
  })
  return buf
end

---Keep windows that show the log (other than the one being typed in)
---following its end while a run streams.
local function follow_log(buf)
  local current = vim.api.nvim_get_current_win()
  local last = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if win ~= current then
      pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
    end
  end
end

---Show a log buffer: reuse a window in this tab, otherwise a split on the
---right edge sized for prose.
local function show_log(buf, opts)
  opts = opts or {}
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    if opts.below then
      vim.cmd("botright split")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_height(win, opts.height or 12)
    else
      vim.cmd("botright vsplit")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_width(win, math.max(60, math.floor(vim.o.columns * 0.35)))
    end
    vim.wo[win].diff = false -- :split copies 'diff' from a diff window
    vim.api.nvim_win_set_buf(win, buf)
  end
  vim.wo[win][0].wrap = true
  vim.wo[win][0].linebreak = true
  pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
  return win
end

---Open the project's Implement log (:MentorImplementLog).
---@return boolean ok, string|nil err
function M.open_log()
  local proj = project_mod.ensure_current()
  if not proj then
    return false, "mentor.nvim: no project context"
  end
  vim.api.nvim_set_current_win(show_log(log_buffer(proj)))
  return true
end

---Append plugin annotations to the session's log at the write position,
---as `⌁ ` lines, leaving an empty line open for further streamed text.
local function session_note(session, text)
  local buf = session and session.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local li = session.line_idx
  local current = vim.api.nvim_buf_get_lines(buf, li, li + 1, false)[1] or ""
  local block = {}
  if current ~= "" then
    block[#block + 1] = current
  end
  for _, part in ipairs(vim.split(text, "\n", { plain = true })) do
    block[#block + 1] = "⌁ " .. part
  end
  block[#block + 1] = ""
  vim.api.nvim_buf_set_lines(buf, li, li + 1, false, block)
  session.line_idx = li + #block - 1
  follow_log(buf)
end

-- ---------------------------------------------------------------------------
-- Review tab: the whole file before and after, in native diff mode
-- ---------------------------------------------------------------------------

local function set_scratch(buf, name, filetype, lines)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and existing ~= buf then
    vim.api.nvim_buf_delete(existing, { force = true })
  end
  if vim.api.nvim_buf_get_name(buf) ~= name then
    pcall(vim.api.nvim_buf_set_name, buf, name)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = filetype
end

---Close a proposal's review tab (if open) and return to the window the
---review was opened from.
local function close_review(p)
  local review = p.review
  if not review then
    return
  end
  p.review = nil
  local was_open = review.tab and vim.api.nvim_tabpage_is_valid(review.tab)
  if was_open and #vim.api.nvim_list_tabpages() > 1 then
    vim.api.nvim_set_current_tabpage(review.tab)
    pcall(vim.cmd, "tabclose")
  end
  for _, b in ipairs({ review.current, review.proposed }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  -- Only a review this call actually closed hands focus back; one the
  -- developer already closed by hand leaves the cursor where it is.
  if was_open and review.origin and vim.api.nvim_win_is_valid(review.origin) then
    vim.api.nvim_set_current_win(review.origin)
  end
end

---Build the before/after buffers for a proposal: the target buffer's full
---text, and the same text with the replacement applied exactly the way
---accepting would apply it.
local function build_review_buffers(p)
  local target = p.target
  local ft = target.filetype ~= "" and target.filetype or "text"
  local lines = vim.api.nvim_buf_get_lines(target.buf, 0, -1, false)
  local cur_buf = vim.api.nvim_create_buf(false, true)
  local prop_buf = vim.api.nvim_create_buf(false, true)
  set_scratch(cur_buf, preview_name(p.id, "current"), ft, lines)
  set_scratch(prop_buf, preview_name(p.id, "proposed"), ft, lines)
  -- Bound to the project, so bare commands typed in the review tab resolve it.
  vim.b[cur_buf].mentor_project = p.project.identity
  vim.b[prop_buf].mentor_project = p.project.identity
  local r = target.range
  vim.bo[prop_buf].modifiable = true
  vim.api.nvim_buf_set_text(prop_buf, r.row1, r.col1, r.row2, r.col2, p.replacement_lines)
  vim.bo[prop_buf].modifiable = false
  return cur_buf, prop_buf
end

---Called by the propose_edit tool. Validates against the frozen target and
---records a proposal; applies are a separate, explicit developer action.
---@param project mentor.Project
---@param args table { replacement, explanation? }
---@return table structured result
function M.intake(project, args)
  local session = sessions[project.id]
  if not session then
    return {
      ok = false,
      error = "no Implement run is active for this project; the target range is fixed by the "
        .. "developer's command and cannot be created or moved from here",
    }
  end
  local cfg = config.get().implement
  local replacement = args.replacement
  -- A linewise range touching the last line covers no trailing EOL, so a
  -- replacement's final newline would materialize a spurious empty line;
  -- normalize it away before any comparison or recording.
  if session.target.mode == "linewise" and session.target.range.eof and replacement:sub(-1) == "\n" then
    replacement = replacement:sub(1, -2)
  end
  -- Mid-buffer, a linewise range covers its final line break; replacement
  -- lines without one would swallow the line that follows, so whole lines
  -- in means whole lines out.
  if
    session.target.mode == "linewise"
    and not session.target.range.eof
    and replacement ~= ""
    and replacement:sub(-1) ~= "\n"
  then
    replacement = replacement .. "\n"
  end
  if cfg.max_replacement_bytes > 0 and #replacement > cfg.max_replacement_bytes then
    return {
      ok = false,
      error = string.format(
        "replacement is %d bytes; the Implement proposal cap is %d bytes; "
          .. "narrow the instruction or the range",
        #replacement,
        cfg.max_replacement_bytes
      ),
    }
  end
  if replacement == session.target.text then
    return {
      ok = false,
      error = "the replacement is identical to the current target range; there would be nothing to change",
    }
  end

  local previous = proposals[session.proposal_id]
  if previous and previous.status == "pending" then
    previous.status = "superseded"
  end

  local id = next_proposal_id
  next_proposal_id = id + 1
  local replacement_lines = replacement == "" and {} or vim.split(replacement, "\n", { plain = true })
  local proposal = {
    id = id,
    project = project,
    target = session.target,
    replacement = replacement,
    replacement_lines = replacement_lines,
    explanation = type(args.explanation) == "string" and args.explanation or nil,
    status = "pending",
    session = session,
  }
  proposals[id] = proposal
  proposal_order[#proposal_order + 1] = proposal
  session.proposal_id = id

  if previous and previous.review then
    close_review(previous)
  end
  session_note(
    session,
    string.format(
      "Proposal #%d recorded: replaces %d byte(s) with %d byte(s) at %s. Nothing has changed yet.",
      id,
      #session.target.text,
      #replacement,
      short_target(session.target)
    )
  )

  return {
    ok = true,
    proposal_id = id,
    replaced_bytes = #session.target.text,
    replacement_bytes = #replacement,
    message = "The proposal is recorded for the developer to review; only an explicit "
      .. "accept applies it. Provide a short explanation in your final message if helpful.",
  }
end

-- ---------------------------------------------------------------------------
-- Acceptance revalidation and apply
-- ---------------------------------------------------------------------------

---Everything that can make a proposal unsafe to apply, rechecked against
---the frozen target. Returns a human reason, or nil when safe.
---@param p table proposal
---@return string|nil
function M._stale_reason(p)
  local target = p.target
  local buf = target.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return "the target buffer no longer exists"
  end
  if not vim.api.nvim_buf_is_loaded(buf) then
    return "the target buffer was closed"
  end
  if vim.api.nvim_buf_get_name(buf) ~= target.bufname then
    return "the buffer no longer shows " .. target.bufname
  end
  if vim.api.nvim_buf_get_var(buf, "changedtick") ~= target.changedtick then
    return "the target buffer changed since the proposal was made "
      .. "(any edit invalidates it, even an edit later undone)"
  end
  if not vim.bo[buf].modifiable then
    return "the target buffer is no longer modifiable"
  end
  local pol = policy_mod.for_project(p.project)
  local _, denied = pol:authorize(target.bufpath)
  if denied then
    return "the target is now off-limits: " .. denied
  end
  return nil
end

local function find_pending(id)
  if id then
    local p = proposals[id]
    if p and p.status == "pending" then
      return p
    end
    return nil
  end
  local proj = project_mod.current()
  for i = #proposal_order, 1, -1 do
    local p = proposal_order[i]
    if p.status == "pending" and (not proj or p.project.id == proj.id) then
      return p
    end
  end
  return nil
end

---@param id_arg string|nil proposal id; defaults to the newest pending one
---@return table|nil proposal applied
---@return string|nil err
function M.accept(id_arg)
  -- The command passes "" when no id is given: that means "the newest".
  id_arg = id_arg and vim.trim(id_arg) or ""
  local id = tonumber(id_arg)
  if id_arg ~= "" and not id then
    return nil, "mentor.nvim: usage: :MentorImplementAccept [proposal-id]"
  end
  local p = find_pending(id)
  if not p then
    return nil,
      "mentor.nvim: no pending Implement proposal"
        .. (id and (" with id " .. id) or "")
        .. " for this project"
  end

  local why = M._stale_reason(p)
  if why then
    p.status = "stale"
    session_note(p.session, "Proposal #" .. p.id .. " expired: " .. why)
    close_review(p)
    return nil, "mentor.nvim: proposal #" .. p.id .. " can no longer be applied: " .. why
  end

  local target = p.target
  local range = target.range
  -- Re-setting 'undolevels' closes the buffer's current undo block
  -- (documented side effect even when the value is unchanged), so the
  -- application forms its own block: one `u` reverts exactly this change.
  local undolevels = vim.bo[target.buf].undolevels
  vim.bo[target.buf].undolevels = undolevels
  local ok, err = pcall(
    vim.api.nvim_buf_set_text,
    target.buf,
    range.row1,
    range.col1,
    range.row2,
    range.col2,
    p.replacement_lines
  )
  if not ok then
    return nil, "mentor.nvim: applying the proposal failed: " .. tostring(err)
  end

  p.status = "applied"
  session_note(
    p.session,
    string.format(
      "Applied proposal #%d to %s. One undo (u) in that buffer reverts it; nothing was written to disk.",
      p.id,
      target.bufname
    )
  )
  close_review(p)
  notify(string.format("Applied proposal #%d to %s (u undoes it; not saved).", p.id, short_target(target)))
  return p
end

---@param id_arg string|nil
---@return table|nil proposal rejected
---@return string|nil err
function M.reject(id_arg)
  -- The command passes "" when no id is given: that means "the newest".
  id_arg = id_arg and vim.trim(id_arg) or ""
  local id = tonumber(id_arg)
  if id_arg ~= "" and not id then
    return nil, "mentor.nvim: usage: :MentorImplementReject [proposal-id]"
  end
  local p = find_pending(id)
  if not p then
    return nil,
      "mentor.nvim: no pending Implement proposal"
        .. (id and (" with id " .. id) or "")
        .. " for this project"
  end
  p.status = "rejected"
  session_note(p.session, "Proposal #" .. p.id .. " rejected; the target buffer was not touched.")
  close_review(p)
  notify("Proposal #" .. p.id .. " rejected; " .. short_target(p.target) .. " was not touched.")
  return p
end

---Open a pending proposal for review in its own tab page
---(:MentorImplementReview): the whole file before (left) and after (right)
---in native diff mode, the project's Implement log below. `a` accepts, `r`
---rejects, `q` closes the tab and keeps the proposal pending.
---@param id_arg string|nil proposal id; defaults to the newest pending one
---@return table|nil proposal
---@return string|nil err
function M.review(id_arg)
  id_arg = id_arg and vim.trim(id_arg) or ""
  local id = tonumber(id_arg)
  if id_arg ~= "" and not id then
    return nil, "mentor.nvim: usage: :MentorImplementReview [proposal-id]"
  end
  local p = find_pending(id)
  if not p then
    return nil,
      "mentor.nvim: no pending Implement proposal"
        .. (id and (" with id " .. id) or "")
        .. " for this project"
  end
  if p.review and vim.api.nvim_tabpage_is_valid(p.review.tab) then
    vim.api.nvim_set_current_tabpage(p.review.tab)
    return p
  end
  local why = M._stale_reason(p)
  if why then
    p.status = "stale"
    session_note(p.session, "Proposal #" .. p.id .. " expired: " .. why)
    return nil, "mentor.nvim: proposal #" .. p.id .. " can no longer be applied: " .. why
  end

  local origin = vim.api.nvim_get_current_win()
  local cur_buf, prop_buf = build_review_buffers(p)
  -- Open the tab straight onto a review buffer: an intermediate empty
  -- buffer (:tabnew) would refocus the project to the working directory.
  vim.cmd("tab sbuffer " .. cur_buf)
  local tab = vim.api.nvim_get_current_tabpage()
  local left = vim.api.nvim_get_current_win()
  vim.wo[left].diff = false
  vim.cmd("rightbelow vsplit")
  local right = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right, prop_buf)
  p.review = { tab = tab, origin = origin, current = cur_buf, proposed = prop_buf }

  local keys = "a accept · r reject · q close (stays pending) · ]c next change"
  for _, w in ipairs({ left, right }) do
    vim.api.nvim_win_call(w, function()
      vim.cmd("diffthis")
    end)
    vim.wo[w][0].wrap = false
  end
  vim.wo[left][0].winbar = string.format(" Proposal #%d · current %s", p.id, short_target(p.target))
  vim.wo[right][0].winbar = string.format(" Proposal #%d · proposed · %s", p.id, keys)

  for _, b in ipairs({ cur_buf, prop_buf }) do
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = b, nowait = true, silent = true, desc = desc })
    end
    map("a", function()
      local _, err = M.accept(tostring(p.id))
      if err then
        vim.notify(err, vim.log.levels.ERROR)
      end
    end, "Accept this Implement proposal")
    map("r", function()
      local _, err = M.reject(tostring(p.id))
      if err then
        vim.notify(err, vim.log.levels.ERROR)
      end
    end, "Reject this Implement proposal")
    map("q", function()
      close_review(p)
    end, "Close the review (the proposal stays pending)")
  end

  if p.session and p.session.buf and vim.api.nvim_buf_is_valid(p.session.buf) then
    show_log(p.session.buf, { below = true, height = math.max(6, math.floor(vim.o.lines * 0.2)) })
  end
  vim.api.nvim_set_current_win(right)
  -- Land on the first change.
  pcall(vim.cmd, "normal! gg]c")
  return p
end

-- ---------------------------------------------------------------------------
-- Run orchestration
-- ---------------------------------------------------------------------------

---Start one Implement run for the current buffer's captured target.
---@param instruction string
---@param req table { range, line1, line2, vmode } from the user command
---@return table|nil handle
---@return string|nil err
function M.start(instruction, req)
  local proj = project_mod.ensure_current()
  if not proj then
    return nil, "mentor.nvim: no project context (open a file inside a project directory)"
  end
  if sessions[proj.id] then
    return nil, "mentor.nvim: an Implement run is already active for this project (:MentorStop cancels it)"
  end

  local target, err = M._capture_target(proj, req)
  if not target then
    return nil, err
  end

  local buf = log_buffer(proj)
  local header = {
    "",
    "## " .. short_target(target),
    "",
    "**Instruction:** " .. instruction,
    "",
    "",
  }
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, header)

  local session = {
    project = proj,
    target = target,
    buf = buf,
    proposal_id = nil,
    line_idx = vim.api.nvim_buf_line_count(buf) - 1,
  }
  sessions[proj.id] = session

  local function append_delta(chunk)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local parts = vim.split(chunk, "\n", { plain = true })
    local li = session.line_idx
    local current = vim.api.nvim_buf_get_lines(buf, li, li + 1, false)[1] or ""
    local replacement = { current .. parts[1] }
    for i = 2, #parts do
      replacement[#replacement + 1] = parts[i]
    end
    vim.api.nvim_buf_set_lines(buf, li, li + 1, false, replacement)
    session.line_idx = li + #replacement - 1
    follow_log(buf)
  end

  -- Interactive work preempts automatic background work on the shared
  -- provider endpoint.
  require("mentor.observer").preempt()

  -- Before the run: a request refused synchronously reports its outcome
  -- from inside agent.run, and that must not precede "running".
  notify("Implement running on " .. short_target(target) .. " (:MentorImplementLog to follow along).")
  local handle, run_err = agent.run({
    mode = "implement",
    kind = "interactive",
    project = proj,
    messages = {
      { role = "system", content = prompts.implement_system(proj, describe_target(target)) },
      { role = "user", content = instruction },
    },
    tools = tools_mod.names({ "investigation", "memory", "implement" }),
    finish_tools = { "propose_edit" },
    on_delta = append_delta,
    on_tool = function(phase, call)
      if phase == "start" then
        session_note(session, call.name)
      end
    end,
    on_done = function(done_err, info)
      if sessions[proj.id] == session then
        sessions[proj.id] = nil
      end
      session.handle = nil
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if done_err == "cancelled" then
        for _, p in ipairs(proposal_order) do
          if p.status == "pending" and p.session == session then
            p.status = "cancelled"
            close_review(p)
          end
        end
        session_note(session, "Cancelled. Any pending proposal from this run has been withdrawn.")
        notify("Implement run on " .. short_target(target) .. " cancelled.")
      elseif done_err then
        local why = bare((info and info.message) or done_err)
        session_note(session, "Failed: " .. why)
        notify(
          "Implement run on " .. short_target(target) .. " failed: " .. why .. " (:MentorImplementLog)",
          vim.log.levels.WARN
        )
      elseif session.proposal_id then
        local p = proposals[session.proposal_id]
        session_note(
          session,
          "Finished. Proposal #" .. session.proposal_id .. " is ready: :MentorImplementReview"
        )
        if p and p.status == "pending" then
          notify(
            string.format(
              "Proposal #%d ready for %s (%d line(s) proposed): :MentorImplementReview",
              p.id,
              short_target(target),
              line_count(p.replacement)
            )
          )
        end
      else
        local why = (info and info.stop_reason and info.stop_reason ~= "stop")
            and ("Stopped without producing a proposal: " .. info.stop_reason)
          or "Finished without producing a proposal."
        session_note(session, why)
        notify(
          "Implement run on " .. short_target(target) .. ": " .. why .. " (:MentorImplementLog)",
          vim.log.levels.WARN
        )
      end
    end,
  })
  if not handle then
    sessions[proj.id] = nil
    session_note(session, "Could not start: " .. bare(run_err))
    return nil, run_err
  end
  session.handle = handle
  return handle
end

---@return integer active runs
function M.active_count()
  local n = 0
  for _ in pairs(sessions) do
    n = n + 1
  end
  return n
end

---@return integer pending proposals
function M.pending_count()
  local n = 0
  for _, p in ipairs(proposal_order) do
    if p.status == "pending" then
      n = n + 1
    end
  end
  return n
end

---Cancel active runs; their pending proposals are withdrawn on completion.
---@return integer cancelled count
function M.stop()
  local n = 0
  for _, session in pairs(sessions) do
    if session.handle and session.handle:is_active() then
      session.handle:cancel()
      n = n + 1
    end
  end
  return n
end

---Drop all in-memory state (isolated checks only).
function M._reset()
  for _, p in ipairs(proposal_order) do
    close_review(p)
  end
  sessions = {}
  proposals = {}
  proposal_order = {}
end

return M
