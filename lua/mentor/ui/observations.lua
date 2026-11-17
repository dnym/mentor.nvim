-- Observation list: the persisted record of everything the Observer found,
-- with the user's control surface (dismiss/restore, category mute/snooze,
-- useful/not-useful rating, and a Coach handoff for deeper explanation).
-- Findings are always stored; this view is presentation and control, never
-- the source of truth. Staleness is recomputed on open from the stored
-- fingerprints, so restored findings show honestly until they are
-- re-confirmed by a later pass.

local project = require("mentor.project")
local config = require("mentor.config")
local records = require("mentor.storage.records")
local clock = require("mentor.clock")

local scratch = require("mentor.ui.scratch")
local M = {}

local obs_buffers = {} -- project identity -> bufnr

local function view_name(identity)
  return "mentor://observations/" .. identity:gsub("^/+", "")
end

---Inline code span that survives backticks inside the text.
local function code_span(text)
  local fence = "`"
  while text:find(fence, 1, true) do
    fence = fence .. "`"
  end
  local pad = (text:sub(1, 1) == "`" or text:sub(-1) == "`") and " " or ""
  return fence .. pad .. text .. pad .. fence
end

local function date_str(ts)
  return clock.format(ts, "%Y-%m-%d %H:%M")
end

---@param row table observation row
---@return string[]
local function block_lines(row)
  local marks = {}
  if row.stale == 1 then
    marks[#marks + 1] = "stale"
  end
  if row.dismissed == 1 then
    marks[#marks + 1] = "dismissed"
  end
  if row.rating then
    marks[#marks + 1] = "rated " .. row.rating
  end
  if row.notified_at then
    marks[#marks + 1] = "notified " .. date_str(row.notified_at)
  end
  local out = {
    string.format(
      "## [o%d] %s · %s · %s%s",
      row.id,
      row.category,
      row.certainty,
      date_str(row.created_at),
      #marks > 0 and (" · " .. table.concat(marks, " · ")) or ""
    ),
    row.summary,
  }
  if row.reasoning ~= "" then
    out[#out + 1] = ""
    for _, line in ipairs(vim.split(row.reasoning, "\n", { plain = true })) do
      out[#out + 1] = line
    end
  end
  if row.refs and row.refs ~= "" then
    local ok, refs = pcall(vim.json.decode, row.refs)
    if ok and type(refs) == "table" and #refs > 0 then
      local spans = {}
      for i, ref in ipairs(refs) do
        spans[i] = code_span(ref)
      end
      out[#out + 1] = ""
      out[#out + 1] = "- **Refs:** " .. table.concat(spans, ", ")
    end
  end
  local tail = {}
  if row.question ~= "" then
    tail[#tail + 1] = "- **Next step:** " .. row.question
  end
  if not row.notified_at and row.notify_note and row.notify_note ~= "" then
    tail[#tail + 1] = "- **Not notified:** " .. row.notify_note
  end
  -- Separate the detail list from the model's reasoning text (which may end
  -- in a list of its own); continue it after the Refs item.
  if #tail > 0 and not out[#out]:match("^%- %*%*Refs:%*%*") then
    out[#out + 1] = ""
  end
  vim.list_extend(out, tail)
  out[#out + 1] = ""
  return out
end

---@param buf integer
---@param proj mentor.Project
local function render(buf, proj)
  local cfg = config.get().observer
  local row_id = records.projects.get(proj.identity) and records.projects.get(proj.identity).id
  local rows = row_id and records.observations.list_all(row_id, cfg.list_max_items) or {}
  local prefs = row_id and records.observer.prefs(row_id) or {}

  local lines = {
    "# Mentor observations",
    "",
    "- Generated view; the database is authoritative.",
    "- Cursor on a finding, then: `d` dismiss · `r` restore · `u` useful · `x` not useful",
    "- `<CR>` ask Coach to explain · `s` snooze this category 30 min · `m` mute/unmute this category",
    "- `R` refresh (revalidate staleness) · `q` close",
  }
  local counts = row_id and records.observations.counts(row_id)
    or { active = 0, stale = 0, dismissed = 0, useful = 0, not_useful = 0 }
  lines[#lines + 1] = string.format(
    "- %d active (%d stale), %d dismissed; rated %d useful / %d not useful",
    counts.active,
    counts.stale,
    counts.dismissed,
    counts.useful,
    counts.not_useful
  )
  for _, pref in ipairs(prefs) do
    if pref.muted == 1 or pref.snooze_until > clock.now_ms() then
      local detail = pref.muted == 1 and " (muted)" or ""
      if pref.snooze_until > clock.now_ms() then
        detail = detail .. " (snoozed until " .. date_str(pref.snooze_until) .. ")"
      end
      lines[#lines + 1] = "- Category " .. pref.category .. detail
    end
  end
  lines[#lines + 1] = ""

  if #rows == 0 then
    lines[#lines + 1] = "(no observations recorded for this project yet)"
  end
  for _, row in ipairs(rows) do
    for _, line in ipairs(block_lines(row)) do
      lines[#lines + 1] = line
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

---Finding id at or above the cursor ("## [oN]" header owns its block).
---@param buf integer
---@return integer|nil
local function finding_at_cursor(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(buf, 0, row, false)
  for i = #lines, 1, -1 do
    local id = lines[i]:match("^## %[o(%d+)%]")
    if id then
      return tonumber(id)
    end
  end
  return nil
end

local function action(buf, fn)
  local identity = vim.b[buf].mentor_project
  local proj = identity and project.for_dir(identity)
  if not proj then
    vim.notify("mentor.nvim: this view's project is no longer resolvable", vim.log.levels.WARN)
    return
  end
  local id = finding_at_cursor(buf)
  if not id then
    vim.notify("mentor.nvim: move the cursor onto a finding (a '## [oN]' block)", vim.log.levels.WARN)
    return
  end
  fn(proj, id)
  render(buf, proj)
end

---Explain handoff: opens Coach with the finding's full context as the
---question. Coach answers interactively; the finding itself stays as stored.
function M.explain(proj, finding_id)
  local row_id = records.projects.get(proj.identity) and records.projects.get(proj.identity).id
  local row = row_id and records.observations.get(finding_id)
  if not row or row.project_id ~= row_id then
    return false, "mentor.nvim: no such observation for this project"
  end
  local refs = ""
  local ok, decoded = pcall(vim.json.decode, row.refs or "[]")
  if ok and type(decoded) == "table" then
    refs = table.concat(decoded, ", ")
  end
  local text = table.concat({
    "I want to understand an observation the Observer recorded for this project:",
    "(id o" .. row.id .. ", category " .. row.category .. ", certainty " .. row.certainty .. ")",
    "Summary: " .. row.summary,
  })
  if row.reasoning ~= "" then
    text = text .. "\nReasoning it gave: " .. row.reasoning
  end
  if refs ~= "" then
    text = text .. "\nIt referenced: " .. refs
  end
  if row.question ~= "" then
    text = text .. "\nSuggested next step: " .. row.question
  end
  text = text
    .. "\n\nExplain why this matters here and what the trade-offs are. "
    .. "Help me think it through rather than rewriting the code for me."
  return require("mentor.ui.chat").ask(text)
end

function M.open()
  local proj = project.ensure_current()
  if not proj then
    return false, "mentor.nvim: no project context"
  end
  if records.projects.get(proj.identity) then
    require("mentor.observer").revalidate_findings(proj)
  end

  local name = view_name(proj.identity)
  local buf = scratch.find(name)
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, buf, name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].bufhidden = "hide"
    -- Markdown: Neovim's bundled treesitter highlighting (and any Markdown
    -- renderer the user has) attaches by filetype.
    vim.bo[buf].filetype = "markdown"
    vim.b[buf].mentor_project = proj.identity

    local function keymap(lhs, fn)
      vim.keymap.set("n", lhs, function()
        action(buf, fn)
      end, { buffer = buf, noremap = true, silent = true })
    end
    keymap("d", function(_proj, id)
      records.observations.set_dismissed(id, true)
    end)
    keymap("r", function(_proj, id)
      records.observations.set_dismissed(id, false)
    end)
    keymap("u", function(_proj, id)
      local row = records.observations.get(id)
      records.observations.set_rating(id, row and row.rating ~= "useful" and "useful" or nil)
    end)
    keymap("x", function(_proj, id)
      local row = records.observations.get(id)
      records.observations.set_rating(id, row and row.rating ~= "not-useful" and "not-useful" or nil)
    end)
    keymap("s", function(p, id)
      local rid = records.projects.get(p.identity).id
      local row = records.observations.get(id)
      if not row then
        return
      end
      local minutes = math.floor(config.get().observer.category_snooze_ms / 60000)
      local until_ms = clock.now_ms() + config.get().observer.category_snooze_ms
      records.observer.set_pref(rid, row.category, nil, until_ms)
      vim.notify(
        string.format(
          "mentor.nvim: %s findings snoozed for %d minute(s) (until %s)",
          row.category,
          minutes,
          date_str(until_ms)
        ),
        vim.log.levels.INFO
      )
    end)
    keymap("m", function(p, id)
      local rid = records.projects.get(p.identity).id
      local row = records.observations.get(id)
      if not row then
        return
      end
      local muted = false
      for _, pref in ipairs(records.observer.prefs(rid)) do
        if pref.category == row.category then
          muted = pref.muted ~= 1
        end
      end
      records.observer.set_pref(rid, row.category, muted, nil)
      vim.notify(
        "mentor.nvim: " .. row.category .. " findings " .. (muted and "muted" or "unmuted"),
        vim.log.levels.INFO
      )
    end)
    keymap("<CR>", function(p, id)
      local okq, err = M.explain(p, id)
      if not okq then
        vim.notify(err, vim.log.levels.ERROR)
      end
    end)
    keymap("R", function()
      require("mentor.observer").revalidate_findings(proj)
      render(buf, proj)
    end)
    vim.keymap.set("n", "q", "<cmd>bdelete<cr>", { buffer = buf, noremap = true, silent = true })
    scratch.wipe_on_unload(buf, "mentor")
  end
  obs_buffers[proj.identity] = buf

  render(buf, proj)
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  -- :vsplit copies 'diff' from a diff window; the list is never part of one.
  vim.wo[win].diff = false
  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win][0].wrap = true
  return true
end

function M.reset()
  obs_buffers = {}
end

return M
