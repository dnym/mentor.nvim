-- Memory inspection/editing view. The buffer is a generated Markdown view:
-- it renders from the database on open, and saving it commits the edit
-- through the memory interface — validating every change against the
-- revision the view was rendered at, committing updates, deletions, and
-- creations in one database transaction, then regenerating from the
-- committed database. A conflict (an entry that changed elsewhere since
-- rendering, e.g. another Neovim instance) rejects the whole save and keeps
-- the proposed text in the buffer untouched. The view is never a file on
-- disk, so interrupted generation always recovers by reopening: SQLite is
-- the only authoritative store.

local project = require("mentor.project")
local config = require("mentor.config")
local memory = require("mentor.memory")

local M = {}

local memory_buffers = {} -- project identity -> bufnr

local function view_name(identity)
  return "mentor://memory/" .. identity:gsub("^/+", "")
end

local function date_str(ts)
  return os.date("%Y-%m-%d", math.floor((ts or 0) / 1000))
end

local function block_lines(e)
  local header = string.format(
    "## [m%d] r%d · %s · %s · %s · %s%s",
    e.id,
    e.revision,
    e.scope,
    e.category,
    e.uncertainty,
    date_str(e.updated_at),
    e.protected and " · protected" or ""
  )
  local out = { header, e.summary }
  for _, line in ipairs(vim.split(e.content, "\n", { plain = true })) do
    out[#out + 1] = line
  end
  if e.refs and #e.refs > 0 then
    out[#out + 1] = "Refs: " .. table.concat(e.refs, ", ")
  end
  out[#out + 1] = ""
  return out
end

---Render the full view; returns the lines and the entry snapshot (id ->
---fields + revision) that save-time validation is diffed against.
---@param proj mentor.Project
---@return string[] lines, table snapshot
local function render(proj)
  local cfg = config.get().memory
  local lines = {
    "# Mentor memory — generated view (the database is authoritative)",
    "#",
    "# Edit an entry's summary (first body line) or content and save (:w) to",
    "# commit; all edits commit in one transaction, then this view regenerates.",
    "# Add a block starting with '## [new]' under a section to create an entry;",
    "# remove a whole block to delete one (reversible via :MentorMemory revert).",
    "# Your edits mark entries protected: the assistant cannot replace them",
    "# until you release protection with :MentorMemory protect <id> off.",
    "# A trailing 'Refs: a, b' line lists the paths/concepts an entry is about.",
    "",
  }
  local snapshot = { ids = {}, entries = {} }

  local entries = memory.list("all", proj, "active")
  if #entries > cfg.view_max_entries then
    lines[#lines + 1] = "# [showing the "
      .. cfg.view_max_entries
      .. " most recent of "
      .. #entries
      .. " entries; older entries are unchanged]"
    local trimmed = {}
    for i = 1, cfg.view_max_entries do
      trimmed[i] = entries[i]
    end
    entries = trimmed
  end

  local function section(title, filtered)
    lines[#lines + 1] = "# " .. title
    lines[#lines + 1] = ""
    if #filtered == 0 then
      lines[#lines + 1] = "(none)"
      lines[#lines + 1] = ""
    end
    for _, e in ipairs(filtered) do
      for _, line in ipairs(block_lines(e)) do
        lines[#lines + 1] = line
      end
      snapshot.ids[#snapshot.ids + 1] = e.id
      snapshot.entries[e.id] = {
        revision = e.revision,
        summary = e.summary,
        content = e.content,
        category = e.category,
        uncertainty = e.uncertainty,
        refs = e.refs,
      }
    end
  end

  local global_entries, project_entries = {}, {}
  for _, e in ipairs(entries) do
    if e.scope == "global" then
      global_entries[#global_entries + 1] = e
    else
      project_entries[#project_entries + 1] = e
    end
  end
  section("Global memory", global_entries)
  section("Project memory — " .. proj.identity, project_entries)
  return lines, snapshot
end

---Parse blocks out of the view buffer.
---@param lines string[]
---@return table[] blocks {id|nil for new, revision, scope, category, uncertainty, summary, content, refs}
local function parse_blocks(lines)
  local blocks = {}
  local current = nil
  local section_scope = "project"
  local body = nil

  local function close()
    if current then
      local summary, content = "", ""
      local refs = nil
      while #body > 0 and vim.trim(body[#body]) == "" do
        table.remove(body)
      end
      -- Pull a trailing Refs line off the body (rendering puts it last).
      local raw = #body > 0 and body[#body]:match("^Refs:%s*(.-)%s*$") or nil
      if raw then
        table.remove(body)
        local list = {}
        for _, item in ipairs(vim.split(raw, ",", { trimempty = true, plain = true })) do
          local ref = vim.trim(item)
          if ref ~= "" then
            list[#list + 1] = ref
          end
        end
        if #list > 0 then
          refs = list
        end
      end
      while #body > 0 and vim.trim(body[#body]) == "" do
        table.remove(body)
      end
      if #body > 0 then
        summary = body[1]
        local parts = {}
        for i = 2, #body do
          parts[#parts + 1] = body[i]
        end
        content = table.concat(parts, "\n")
      end
      current.summary = summary
      current.content = content
      current.refs = refs
      if current.id == nil then
        -- New blocks take the section they sit under.
        current.scope = section_scope
      end
      blocks[#blocks + 1] = current
    end
    current = nil
    body = nil
  end

  for _, line in ipairs(lines) do
    local id = line:match("^## %[m(%d+)%]")
    local is_new = line:match("^## %[new%]") ~= nil
    if id or is_new then
      close()
      local parts = vim.split(line, " · ", { plain = true })
      local revision = tonumber(parts[1] and parts[1]:match("r(%d+)") or "")
      current = {
        id = id and tonumber(id) or nil,
        revision = revision,
        scope = parts[2] == "global" and "global" or "project",
        category = parts[3],
        uncertainty = parts[4],
        protected = false,
      }
      for i = 5, #parts do
        if parts[i] == "protected" then
          current.protected = true
        end
      end
      body = {}
    elseif line:match("^# ") then
      close()
      if line:match("^# Global memory") then
        section_scope = "global"
      else
        section_scope = "project"
      end
    elseif current then
      body[#body + 1] = line
    end
  end
  close()
  return blocks
end

---Save handler: diff against the render-time snapshot, validate, commit
---atomically, regenerate; on any problem the buffer stays untouched with its
---proposed text.
local function save(buf)
  local identity = vim.b[buf].mentor_project
  local proj = project.for_dir(identity)
  if not proj or proj.identity ~= identity then
    vim.notify("mentor.nvim: the memory view's project is no longer resolvable", vim.log.levels.ERROR)
    return
  end
  local snapshot = vim.b[buf].mentor_memory_snapshot
  local blocks = parse_blocks(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local edits = { updates = {}, creates = {}, deletes = {} }
  local seen = {}
  for _, b in ipairs(blocks) do
    if b.id == nil then
      if vim.trim(b.summary) == "" then
        vim.notify("mentor.nvim memory: a '## [new]' block needs a summary line", vim.log.levels.ERROR)
        return
      end
      -- Metadata on new blocks is the user's choice; default sensibly.
      edits.creates[#edits.creates + 1] = {
        scope = b.scope,
        category = b.category or "note",
        summary = b.summary,
        content = b.content,
        uncertainty = b.uncertainty or "established",
        refs = b.refs,
      }
    else
      seen[b.id] = true
      local prev = snapshot.entries[b.id]
      local changed = not prev
      if prev then
        changed = prev.summary ~= b.summary
          or prev.content ~= b.content
          or prev.category ~= b.category
          or prev.uncertainty ~= b.uncertainty
          or table.concat(prev.refs or {}, "\u{1}") ~= table.concat(b.refs or {}, "\u{1}")
      end
      if changed then
        edits.updates[#edits.updates + 1] = {
          id = b.id,
          expected_revision = b.revision or (prev and prev.revision) or 0,
          summary = b.summary,
          content = b.content,
          category = b.category,
          uncertainty = b.uncertainty,
          refs = b.refs,
        }
      end
    end
  end
  for _, id in ipairs(snapshot.ids) do
    if not seen[id] then
      edits.deletes[#edits.deletes + 1] = id
    end
  end

  if #edits.updates == 0 and #edits.creates == 0 and #edits.deletes == 0 then
    local lines2, snap2 = render(proj)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines2)
    vim.b[buf].mentor_memory_snapshot = snap2
    vim.bo[buf].modified = false
    return
  end

  local result = memory.apply_view_edits(proj, edits)
  if not result.ok then
    for _, problem in ipairs(result.problems) do
      vim.notify("mentor.nvim memory: " .. problem, vim.log.levels.ERROR)
    end
    vim.notify(
      "mentor.nvim memory: nothing was saved; the buffer keeps your proposed text. Reopen with :MentorMemory to see current entries.",
      vim.log.levels.WARN
    )
    return
  end
  -- Regenerate unconditionally from the committed database: the buffer was
  -- modified, so a conditional refresh would miss it, and the snapshot must
  -- move to the new revisions or the next save would report false conflicts.
  local lines2, snap2 = render(proj)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines2)
  vim.b[buf].mentor_memory_snapshot = snap2
  vim.bo[buf].modified = false
  vim.notify(
    string.format(
      "mentor.nvim memory: committed %d edit(s), %d creation(s), %d deletion(s)",
      #edits.updates,
      #edits.creates,
      #edits.deletes
    ),
    vim.log.levels.INFO
  )
end

---Regenerate the view for a project when its buffer is open and unmodified.
---@param proj mentor.Project
function M.refresh(proj)
  local buf = memory_buffers[proj.identity]
  if buf and vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
    local lines, snapshot = render(proj)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.b[buf].mentor_memory_snapshot = snapshot
  end
end

---Opens (or focuses) the memory view for the current project.
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
  local name = view_name(proj.identity)
  local existing = memory_buffers[proj.identity]
  if existing and vim.api.nvim_buf_is_valid(existing) then
    local win = vim.fn.bufwinid(existing)
    if win == -1 then
      vim.cmd("vsplit")
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), existing)
    else
      vim.api.nvim_set_current_win(win)
    end
    return existing
  end

  local buf = vim.fn.bufnr(name)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].modifiable = true
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].mentor_project = proj.identity

  local lines, snapshot = render(proj)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.b[buf].mentor_memory_snapshot = snapshot
  vim.bo[buf].modified = false

  -- The buffer may be a recycled hidden one; clear stale handlers first.
  vim.api.nvim_clear_autocmds({ buffer = buf, group = "mentor" })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    group = "mentor",
    callback = function()
      save(buf)
    end,
  })
  vim.api.nvim_create_autocmd("bufwipeout", {
    buffer = buf,
    group = "mentor",
    callback = function()
      memory_buffers[proj.identity] = nil
    end,
  })
  memory_buffers[proj.identity] = buf

  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
  return buf
end

---If this buffer is a memory view, regenerate it from the database (used
---after command-driven changes to keep open views honest).
function M.refresh_if_open(proj)
  M.refresh(proj)
end

return M
