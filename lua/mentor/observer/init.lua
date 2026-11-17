-- Observer engine: activation, triggers, bounded background investigation,
-- and the publication pipeline (freshness revalidation, deduplication,
-- persistence, notification policy).
--
-- Activation is per project and stored with the Observer endpoint accepted
-- at enable time: changing the endpoint disables observation until the user
-- explicitly enables it again, and a disabled project stays disabled across
-- restarts. Pausing is instance-only. Automatic triggers (edits followed by
-- an idle period, saves debounced separately) never start a pass during
-- Insert mode; pending work is reconsidered after leaving it. Each project
-- keeps at most one pending job, coalescing to the newest state, and each
-- instance runs at most one background investigation.
--
-- The engine never modifies buffers. Findings reported by the model are
-- validated (refs re-authorized against the current policy), fingerprinted
-- for staleness, deduplicated by issue kind + location, persisted, and only
-- then presented through the notification policy (category rules, per-
-- finding cooldown, per-project pacing, mute/snooze, typing suppression).
-- A cancellation generation ensures late results can never publish.

local config = require("mentor.config")
local project = require("mentor.project")
local policy_mod = require("mentor.policy")
local provider_mod = require("mentor.provider")
local records = require("mentor.storage.records")
local prompts = require("mentor.prompts")
local memory_mod = require("mentor.memory")
local tools_mod = require("mentor.tools")
local clock = require("mentor.clock")

local M = {}

-- project identity -> per-project state
local states = {}
---@type table|nil the single running background observation state
local running = nil
-- finding ids created in this instance (restored findings start stale)
local fresh = {}
local installed = false

local function mode_is_insert()
  local ok, m = pcall(vim.fn.mode)
  return ok and m == "i"
end

-- Replaceable by tests: Insert mode cannot be held in the headless harness.
local insert_probe = mode_is_insert

local function in_insert()
  return insert_probe()
end

local function slugify(text)
  local s = (text:lower():gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", ""))
  if #s > 64 then
    s = s:sub(1, 64):gsub("-+$", "")
  end
  return s
end

-- ---------------------------------------------------------------------------
-- Fingerprints and revalidation

---@param abspath string
---@return table|nil { sec, nsec, size, tick, path } current fingerprint
local function fingerprint_now(abspath)
  local fp = { path = abspath }
  local filled = false
  local stat = vim.uv.fs_stat(abspath)
  if stat then
    fp.sec, fp.nsec, fp.size = stat.mtime.sec, stat.mtime.nsec, stat.size
    filled = true
  end
  local buf = vim.fn.bufnr(abspath, false)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    fp.tick = vim.api.nvim_buf_get_changedtick(buf)
    filled = true
  end
  if not filled then
    return nil
  end
  return fp
end

---A stored fingerprint still describes the current state. When the claim
---was about unsaved buffer content only the live buffer version can confirm
---it; otherwise the disk file is the reference (a clean buffer whose file
---moved underneath it is honestly stale).
---@param fp table stored fingerprint
---@return boolean
local function fingerprint_matches(fp)
  if type(fp) ~= "table" or not fp.path then
    return false
  end
  local buf = vim.fn.bufnr(fp.path, false)
  local loaded = buf ~= -1 and vim.api.nvim_buf_is_loaded(buf)
  if loaded and vim.bo[buf].modified then
    return fp.tick ~= nil and vim.api.nvim_buf_get_changedtick(buf) == fp.tick
  end
  if fp.sec then
    local stat = vim.uv.fs_stat(fp.path)
    return stat ~= nil and stat.size == fp.size and stat.mtime.sec == fp.sec and stat.mtime.nsec == fp.nsec
  end
  if fp.tick and loaded then
    return vim.api.nvim_buf_get_changedtick(buf) == fp.tick
  end
  return false
end

-- ---------------------------------------------------------------------------
-- State and activation

---@class mentor.ObserverState
---@field identity string
---@field proj mentor.Project
---@field project_id integer
---@field enabled boolean persisted activation decision
---@field paused boolean instance-only pause
---@field pending table|nil coalesced pending job { reason }
---@field handle table|nil running agent handle
---@field timer userdata|nil armed trigger timer
---@field baseline table|nil digest fingerprint snapshot for the running pass
---@field op_tool_ctx table|nil the running agent operation's tool context
---@field generation integer bumped to drop late results
---@field last_notify integer last notification time (pacing, epoch ms)
---@field deferred integer[] finding ids held back while typing
---@field last_error string|nil most recent skipped-run reason (status)

---@param proj mentor.Project
---@return mentor.ObserverState|nil
local function state_for(proj)
  if not proj or not proj.identity then
    return nil
  end
  local st = states[proj.identity]
  if st then
    st.proj = proj
    return st
  end
  st = {
    identity = proj.identity,
    proj = proj,
    project_id = records.projects.touch({
      identity = proj.identity,
      root = proj.root,
      is_git = proj.is_git,
      git_common_dir = proj.git_common_dir,
    }),
    enabled = false,
    paused = false,
    pending = nil,
    handle = nil,
    timer = nil,
    baseline = nil,
    op_tool_ctx = nil,
    generation = 0,
    last_notify = 0,
    deferred = {},
    last_error = nil,
  }
  states[proj.identity] = st

  -- Restored findings describe a state this instance has not re-verified:
  -- they start stale (opening the observation list revalidates them).
  for _, row in ipairs(records.observations.list_active(st.project_id)) do
    if not fresh[row.id] then
      records.observations.set_stale(row.id, true)
    end
  end

  local row = records.observer.state(st.project_id)
  if row and row.enabled == 1 then
    local endpoint = config.provider_for("observer").endpoint
    if endpoint == "" or (row.endpoint or "") ~= endpoint then
      -- The endpoint changed (or vanished) since activation: persisted off.
      records.observer.set_enabled(st.project_id, false, "")
      vim.schedule(function()
        vim.notify(
          "mentor.nvim: Observer stays off for "
            .. proj.identity
            .. ": its provider endpoint changed since activation. Run :MentorObserve enable to turn it back on.",
          vim.log.levels.INFO
        )
      end)
    else
      st.enabled = true
    end
  end
  return st
end

---@param st mentor.ObserverState
---@param clear_pending boolean
local function cancel_state(st, clear_pending)
  st.generation = st.generation + 1
  if st.timer then
    st.timer:stop()
    if not st.timer:is_closing() then
      st.timer:close()
    end
    st.timer = nil
  end
  if st.handle then
    st.handle:cancel()
    st.handle = nil
    st.op_tool_ctx = nil
    if running == st then
      running = nil
    end
  end
  if clear_pending then
    st.pending = nil
    st.deferred = {}
  end
end

---Re-check the persisted activation against the current endpoint (covers a
---config change inside one instance). Returns true when observation stands.
---@param st mentor.ObserverState
---@return boolean
local function activation_current(st)
  if not st.enabled then
    return false
  end
  local row = records.observer.state(st.project_id)
  local endpoint = config.provider_for("observer").endpoint
  if not row or row.enabled ~= 1 or (row.endpoint or "") ~= endpoint or endpoint == "" then
    st.enabled = false
    records.observer.set_enabled(st.project_id, false, "")
    cancel_state(st, true)
    vim.schedule(function()
      vim.notify(
        "mentor.nvim: Observer disabled for "
          .. st.identity
          .. ": the configured endpoint no longer matches the one that was activated.",
        vim.log.levels.INFO
      )
    end)
    return false
  end
  return true
end

function M.enable(proj)
  proj = proj or project.ensure_current()
  if not proj then
    return false, "mentor.nvim: no project context"
  end
  local missing = provider_mod.missing("observer")
  if missing then
    return false, missing
  end
  if config.provider_for("observer").endpoint == "" then
    return false,
      "mentor.nvim: set providers.observer.endpoint (or providers.default.endpoint) before enabling observation"
  end
  local st = state_for(proj)
  st.enabled = true
  st.paused = false
  st.last_error = nil
  records.observer.set_enabled(st.project_id, true, config.provider_for("observer").endpoint)
  vim.notify(
    table.concat({
      "mentor.nvim: Observer is ON for " .. proj.identity .. ".",
      "Automatic passes will send change digests of this project — including unsaved code inside",
      "the access policy — to the Observer provider (" .. config.provider_for("observer").endpoint .. ").",
      "Findings are deduplicated and rate-limited; :MentorObserve disable turns this off, :MentorObservations shows them.",
    }, "\n"),
    vim.log.levels.INFO
  )
  return true
end

function M.disable(proj)
  proj = proj or project.ensure_current()
  if not proj then
    return false, "mentor.nvim: no project context"
  end
  local st = state_for(proj)
  st.enabled = false
  st.paused = false
  records.observer.set_enabled(st.project_id, false, "")
  cancel_state(st, true)
  vim.notify(
    "mentor.nvim: Observer is OFF for " .. proj.identity .. " (persisted across restarts).",
    vim.log.levels.INFO
  )
  return true
end

---Instance-only pause: stops background work now, leaves persisted
---activation alone. A restart resumes whatever was enabled.
function M.pause(proj)
  proj = proj or project.ensure_current()
  if not proj then
    return false, "mentor.nvim: no project context"
  end
  local st = state_for(proj)
  if not st.enabled then
    return false, "mentor.nvim: Observer is not enabled for this project (:MentorObserve enable)"
  end
  st.paused = true
  cancel_state(st, true)
  vim.notify("mentor.nvim: Observer paused for this session (:MentorObserve resume).", vim.log.levels.INFO)
  return true
end

function M.resume(proj)
  proj = proj or project.ensure_current()
  if not proj then
    return false, "mentor.nvim: no project context"
  end
  local st = state_for(proj)
  if not st.enabled then
    return false, "mentor.nvim: Observer is not enabled for this project (:MentorObserve enable)"
  end
  st.paused = false
  vim.notify("mentor.nvim: Observer resumed for " .. proj.identity .. ".", vim.log.levels.INFO)
  return true
end

-- ---------------------------------------------------------------------------
-- Change digest

---@param proj mentor.Project
---@param args string[]
---@return string|nil
local function git_text(proj, args, timeout_ms)
  local argv = { "git", "--no-pager", "-C", proj.root, "--no-optional-locks", "-c", "core.quotepath=false" }
  vim.list_extend(argv, args)
  local ok, res = pcall(vim.system, argv, { text = true, timeout = timeout_ms or 3000 })
  if not ok then
    return nil
  end
  local out = res:wait()
  if out.code ~= 0 then
    return nil
  end
  return out.stdout or ""
end

---Normal buffers of the project keyed by normalized absolute path.
---@param proj mentor.Project
---@return table<string, integer>
local function project_buffers(proj)
  local by_path = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local rec = project.for_buf(buf)
        if rec and rec.identity == proj.identity then
          by_path[vim.fs.normalize(name)] = buf
        end
      end
    end
  end
  return by_path
end

local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

---@param abspath string
---@param cap_bytes integer
---@return string|nil nil = unreadable or larger than the cap
local function disk_text(abspath, cap_bytes)
  local stat = vim.uv.fs_stat(abspath)
  if not stat or stat.size > cap_bytes then
    return nil
  end
  local f = io.open(abspath, "rb")
  if not f then
    return nil
  end
  local text = f:read(math.max(cap_bytes, 1)) or ""
  f:close()
  return text
end

---Strip vim.diff's own file header lines so the engine labels the sides.
local function diff_body(patch)
  local lines = vim.split(patch, "\n", { plain = true })
  local i = 1
  while i <= #lines and (lines[i]:sub(1, 3) == "---" or lines[i]:sub(1, 3) == "+++") do
    i = i + 1
  end
  return table.concat(lines, "\n", i)
end

---@param proj mentor.Project
---@return string digest, table baseline { paths, policy_generation, head }
local function build_digest(proj)
  local ocfg = config.get().observer
  local policy = policy_mod.for_project(proj)
  local buffers = project_buffers(proj)
  local baseline = { paths = {}, policy_generation = policy.generation, head = nil }
  local parts = {}
  local total = 0
  local truncated = false

  local function push(text)
    if truncated then
      return
    end
    if total + #text > ocfg.digest_total_bytes then
      local room = ocfg.digest_total_bytes - total
      if room > 80 then
        parts[#parts + 1] = text:sub(1, room) .. "\n[digest truncated: total byte cap]"
        total = ocfg.digest_total_bytes
      end
      truncated = true
      return
    end
    total = total + #text
    parts[#parts + 1] = text
  end

  ---Record which source the digest text for this path came from.
  local function record_source(abspath, from_buffer, bufnr)
    if from_buffer and bufnr then
      baseline.paths[abspath] = { path = abspath, tick = vim.api.nvim_buf_get_changedtick(bufnr) }
    else
      baseline.paths[abspath] = fingerprint_now(abspath)
    end
  end

  local function file_section(rel, abspath, base_text, base_label, bufnr)
    local new_text, new_label, from_buffer
    if bufnr and vim.bo[bufnr].modified then
      new_text, new_label, from_buffer = buffer_text(bufnr), "buffer (unsaved edits)", true
    else
      new_text, new_label = disk_text(abspath, ocfg.digest_file_bytes), "disk"
    end
    if new_text == nil then
      push(rel .. " (changed; content not included: too large or unreadable)")
      record_source(abspath, false, nil)
      return
    end
    record_source(abspath, from_buffer, bufnr)
    local patch = vim.diff(base_text or "", new_text, { algorithm = "myers" })
    if patch == nil or #vim.trim(patch) == 0 then
      push(rel .. " (changed; no textual difference captured)")
      return
    end
    local body = diff_body(patch)
    if #body > ocfg.digest_file_bytes then
      body = body:sub(1, ocfg.digest_file_bytes) .. "\n[file diff truncated]"
    end
    push(string.format("%s (%s -> %s)\n%s", rel, base_label, new_label, body))
  end

  local function modified_buffer_sections(skipped_paths)
    for abspath, bufnr in pairs(buffers) do
      if vim.bo[bufnr].modified and skipped_paths[abspath] == nil then
        local access = policy:authorize(abspath)
        if access then
          local disk = disk_text(abspath, ocfg.digest_file_bytes)
          file_section(
            vim.fn.fnamemodify(abspath, ":."),
            abspath,
            disk or "",
            disk ~= nil and "disk" or "empty (new file)",
            bufnr
          )
        end
      end
    end
  end

  if proj.is_git then
    local head = git_text(proj, { "rev-parse", "HEAD" }, 2000)
    baseline.head = head and vim.trim(head) or nil
    local raw = git_text(proj, { "status", "--porcelain", "-z" }) or ""
    local tokens = vim.split(raw, "\0", { plain = true })
    local changed = {}
    local i = 1
    while i <= #tokens do
      local tok = tokens[i]
      i = i + 1
      if #tok >= 4 and tok:sub(1, 1) ~= ":" then
        local xy = tok:sub(1, 2)
        local rel = vim.trim(tok:sub(4))
        if xy:find("[RC]") then
          i = i + 1 -- -z puts the source path in the next field
        end
        if rel ~= "" then
          changed[#changed + 1] = { rel = rel, untracked = xy == "??" }
        end
      end
    end
    if #changed == 0 then
      push("No changes reported against HEAD; recent buffer edits may already be committed.")
    end
    local diffed, hidden = 0, 0
    for _, ch in ipairs(changed) do
      local abspath = vim.fs.normalize(proj.root .. "/" .. ch.rel)
      local access = policy:authorize(abspath)
      if not access then
        hidden = hidden + 1
      elseif diffed < 12 then
        diffed = diffed + 1
        local base_text, base_label = "", "empty (new file)"
        if not ch.untracked then
          base_text = git_text(proj, { "show", "HEAD:" .. ch.rel }) or ""
          base_label = "HEAD"
        end
        file_section(ch.rel, abspath, base_text, base_label, buffers[abspath])
      else
        push(ch.rel .. " (changed; diff not shown: per-pass file cap reached)")
      end
    end
    if hidden > 0 then
      push("(" .. hidden .. " changed file(s) hidden by the access policy)")
    end
    -- Modified buffers invisible to Git (ignored, or identical to HEAD after
    -- an edit-and-undo) still matter: their in-editor state is freshest.
    modified_buffer_sections(baseline.paths)
  else
    modified_buffer_sections({})
    if next(baseline.paths) == nil then
      push("No unsaved changes in project buffers; inspect recent files directly.")
    end
  end

  return table.concat(parts, "\n\n"), baseline
end

-- ---------------------------------------------------------------------------
-- Publication pipeline

local function looks_like_path(ref)
  return ref:find("/") ~= nil or ref:match("%.%w$") ~= nil or ref:match("^[%w_]+%.%w") ~= nil
end

---@param f table normalized finding from the reporting tool
---@param rels string[] authorized project-relative refs
---@return string dedup key
local function issue_digest(f, rels)
  if f.issue_key and f.issue_key ~= "" then
    return slugify(f.issue_key)
  end
  return slugify(f.category .. "|" .. (rels[1] or "-") .. "|" .. f.summary:sub(1, 60))
end

---Revalidate the pass's dependencies: digest sources, the access-policy
---generation, the checkout, and everything the tools read during the pass.
---@param st mentor.ObserverState
---@return boolean invalidated, string|nil reason
local function revalidate(st)
  local b = st.baseline
  if not b then
    return true, "no baseline recorded for this pass"
  end
  if b.policy_generation ~= policy_mod.generation() then
    return true, "the access policy changed"
  end
  for _, fp in pairs(b.paths) do
    if not fingerprint_matches(fp) then
      return true, "a source changed while the pass was running"
    end
  end
  if b.head then
    local head = git_text(st.proj, { "rev-parse", "HEAD" }, 2000)
    if head and vim.trim(head) ~= b.head then
      return true, "the checkout changed"
    end
  end
  if st.op_tool_ctx and st.op_tool_ctx.tracker then
    local current = st.op_tool_ctx.tracker:verify()
    if not current then
      return true, "a tool-read source changed while the pass was running"
    end
  end
  return false, nil
end

---Presentation policy: should this finding interrupt the developer now?
---The reason is stored with the finding so the list can explain a silent
---one; `deferred` marks the one suppression that is only postponed (typing).
---@return boolean notify, string|nil reason when suppressed, boolean|nil deferred
local function may_notify(st, f, stale, prior, now)
  local ocfg = config.get().observer
  if stale then
    return false, "stale by the time the pass finished"
  end
  if f.category == "praise" then
    return false, "praise never interrupts"
  end
  if f.category == "design" and f.certainty == "low" then
    return false, "low-confidence design guidance stays in the list"
  end
  if f.category == "learning" and not ocfg.notify_learning then
    return false, "learning findings interrupt only when observer.notify_learning is on"
  end
  for _, pref in ipairs(records.observer.prefs(st.project_id)) do
    if pref.category == f.category then
      if pref.muted == 1 then
        return false, "the " .. f.category .. " category is muted"
      end
      if pref.snooze_until > now then
        return false, "the " .. f.category .. " category is snoozed"
      end
    end
  end
  if prior and prior.dismissed == 1 then
    -- Re-confirmation of a dismissed finding: only after the cooldown.
    local base = prior.notified_at or prior.created_at
    if now - base < ocfg.notify_cooldown_ms then
      return false, "dismissed finding re-confirmed within the cooldown"
    end
  elseif prior and prior.notified_at and now - prior.notified_at < ocfg.notify_cooldown_ms then
    return false, "finding cooldown"
  end
  if now - st.last_notify < ocfg.notify_min_gap_ms then
    return false, "at most one unsolicited notification per project per minute"
  end
  if in_insert() then
    return false, "held back while typing; it notifies after you leave Insert mode", true
  end
  return true
end

local function announce(row)
  vim.notify(
    string.format(
      "Observer [%s/%s] %s\n(:MentorObservations for details, :MentorExplain %d for a Coach handoff)",
      row.category,
      row.certainty,
      row.summary,
      row.id
    ),
    vim.log.levels.INFO
  )
end

---@param row table observation row
---@return boolean current the stored fingerprints still describe the files
local function row_current(row)
  local ok, fps = pcall(vim.json.decode, row.fingerprints or "")
  if not ok or type(fps) ~= "table" then
    return true -- no file-based claim to go stale
  end
  for _, fp in pairs(fps) do
    if not fingerprint_matches(fp) then
      return false
    end
  end
  return true
end

---Findings held back while typing get their chance once Insert mode ends,
---under the same policy re-checked against the current state (mute/snooze
---set meanwhile, pacing, a source edited since the pass).
---@param st mentor.ObserverState
local function flush_deferred(st)
  if #st.deferred == 0 or in_insert() then
    return
  end
  local ids = st.deferred
  st.deferred = {}
  local now = clock.now_ms()
  for _, id in ipairs(ids) do
    local row = records.observations.get(id)
    if row and row.dismissed == 0 and not row.notified_at then
      local notify, reason, deferred
      if row.stale == 1 or not row_current(row) then
        records.observations.set_stale(id, true)
        notify, reason = false, "a source changed while it was held back for typing"
      else
        notify, reason, deferred = may_notify(st, row, false, nil, now)
      end
      if notify then
        records.observations.mark_notified(id, now)
        st.last_notify = now
        announce(row)
      else
        if deferred then
          st.deferred[#st.deferred + 1] = id
        end
        records.observations.set_notify_note(id, reason)
      end
    end
  end
end

---@param st mentor.ObserverState
---@param sink table[] findings reported by the model (normalized by the tool)
local function publish(st, sink)
  if #sink == 0 then
    return -- explicit no-result from the model: nothing to persist
  end
  local stale_pass = revalidate(st)
  local policy = policy_mod.for_project(st.proj)
  local now = clock.now_ms()
  local to_notify = {}

  for _, f in ipairs(sink) do
    -- Re-authorize every path ref against the CURRENT policy; a claim that
    -- rests on a newly excluded path is withheld entirely.
    local rels, fps = {}, {}
    local withheld = false
    for _, ref in ipairs(f.refs) do
      local access = policy:authorize(ref)
      if not access then
        local guess = ref:sub(1, 1) == "/" and ref or (st.proj.root .. "/" .. ref)
        access = policy:authorize(vim.fs.normalize(guess))
      end
      if access then
        local abspath = vim.fs.normalize(st.proj.root .. "/" .. access.rel)
        rels[#rels + 1] = access.rel
        local fp = fingerprint_now(abspath)
        if fp then
          fps[abspath] = fp
        end
      elseif looks_like_path(ref) then
        withheld = true
        break
      end
      -- non-path refs (concepts) are tolerated text
    end
    if withheld then
      goto continue
    end
    -- Concrete claims must rest on verified, still-authorized files.
    if (f.category == "correctness" or f.category == "design") and f.certainty ~= "low" and #rels == 0 then
      goto continue
    end

    local digest = issue_digest(f, rels)
    local prior = records.observations.latest_by_digest(st.project_id, digest)
    if prior and prior.dismissed == 0 then
      goto continue -- duplicate of an active finding
    end

    local id = records.observations.insert({
      project_id = st.project_id,
      category = f.category,
      summary = f.summary,
      reasoning = f.reasoning,
      certainty = f.certainty,
      refs = rels,
      fingerprints = fps,
      question = f.question,
      issue_digest = digest,
      stale = stale_pass,
    })
    fresh[id] = true

    local notify, reason, deferred = may_notify(st, f, stale_pass, prior, now)
    if notify then
      records.observations.mark_notified(id, now)
      st.last_notify = now
      to_notify[#to_notify + 1] = id
    else
      records.observations.set_notify_note(id, reason)
      if deferred then
        st.deferred[#st.deferred + 1] = id
      end
    end
    ::continue::
  end

  for _, id in ipairs(to_notify) do
    local row = records.observations.get(id)
    if row then
      announce(row)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Consolidation scheduling (at most once per project per day, only while
-- observation is enabled and redundant memory work is actually pending)

local function maybe_consolidate(st)
  if not st.enabled or st.paused or running then
    return
  end
  local ok, consolidate = pcall(require, "mentor.memory.consolidate")
  if not ok then
    return
  end
  if consolidate.is_active() or consolidate.pending(st.proj) == 0 then
    return
  end
  local day = records.usage.today()
  if records.observer.consolidation_day(st.project_id) == day then
    return
  end
  local handle, err = consolidate.run(st.proj, {})
  if handle then
    records.observer.set_consolidation_day(st.project_id, day)
  elseif err then
    vim.schedule(function()
      vim.notify(err, vim.log.levels.DEBUG)
    end)
  end
end

-- ---------------------------------------------------------------------------
-- Runs

local fire, start_run

fire = function(st, reason)
  if not st.enabled or st.paused then
    return
  end
  if not activation_current(st) then
    return
  end
  if in_insert() then
    st.pending = { reason = reason }
    return
  end
  if running then
    st.pending = { reason = reason }
    return
  end
  start_run(st, reason)
end

start_run = function(st, reason)
  st.pending = nil
  local missing = provider_mod.missing("observer")
  if missing then
    st.last_error = missing
    return
  end
  st.last_error = nil

  local digest, baseline = build_digest(st.proj)
  st.baseline = baseline

  local system = prompts.observer_system(st.proj, digest)
  local mem_block = memory_mod.render_context(st.proj)
  if mem_block ~= "" then
    system = system .. "\n\n" .. mem_block
  end
  local messages = {
    { role = "system", content = system },
    {
      role = "user",
      content = "Review the recent changes described above. Investigate with the read-only tools, "
        .. "then call report_observations exactly once (an empty findings list is a fine outcome).",
    },
  }

  local sink = {}
  local generation = st.generation
  local handle, run_err = require("mentor.agent").run({
    mode = "observer",
    kind = "background",
    project = st.proj,
    messages = messages,
    tools = tools_mod.names({ "investigation", "memory", "observer" }),
    finish_tools = { "report_observations" },
    tool_ctx_extra = { findings_sink = sink },
    on_done = function(err, info)
      st.handle = nil
      st.op_tool_ctx = nil
      if running == st then
        running = nil
      end
      if err == "cancelled" or generation ~= st.generation then
        return -- preempted/paused/disabled mid-pass: late results never publish
      end
      if not sink.reported then
        -- Surface it in :MentorStatus: otherwise a pass that ran out of
        -- budget looks exactly like a clean one.
        st.last_error = "the last pass ended without reporting: "
          .. ((info and (info.message or info.stop_reason)) or err or "no report")
      end
      publish(st, sink)
      if st.pending and st.enabled and not st.paused then
        fire(st, st.pending.reason) -- coalesced rerun against the newest state
      end
      maybe_consolidate(st)
    end,
  })
  if not handle then
    st.last_error = run_err
    return
  end
  st.handle = handle
  st.op_tool_ctx = handle.tool_ctx
  running = st
end

---Explicit review run. Works without activation; everything else (policy,
---budgets, publication checks) applies the same.
---@return boolean ok, string|nil actionable note or error
function M.review(proj)
  proj = proj or project.ensure_current()
  if not proj then
    return false, "mentor.nvim: no project context"
  end
  local missing = provider_mod.missing("observer")
  if missing then
    return false, missing
  end
  local st = state_for(proj)
  if st.handle then
    st.pending = { reason = "review" }
    return true, "mentor.nvim: an observation pass is already running; the review is queued"
  end
  start_run(st, "review")
  if not st.handle then
    return false, "mentor.nvim: " .. tostring(st.last_error or "the pass could not start")
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Triggers

---@param st mentor.ObserverState
---@param ms integer
---@param reason string
local function arm_timer(st, ms, reason)
  if st.timer then
    st.timer:stop()
    if not st.timer:is_closing() then
      st.timer:close()
    end
    st.timer = nil
  end
  local timer = vim.uv.new_timer()
  st.timer = timer
  timer:start(math.max(1, ms), 0, function()
    if st.timer == timer then
      st.timer = nil
    end
    vim.schedule(function()
      fire(st, reason)
    end)
  end)
end

---A project buffer change or save; both automatic triggers share one
---pending slot per project and coalesce to the newest state.
local function activity(ev_buf, kind)
  if vim.bo[ev_buf].buftype ~= "" or vim.api.nvim_buf_get_name(ev_buf) == "" then
    return
  end
  local proj = project.for_buf(ev_buf)
  if not proj then
    return
  end
  local st = states[proj.identity]
  if not st then
    -- Load persisted activation lazily on the first activity (a project
    -- enabled in an earlier session stays enabled).
    if not records.projects.get(proj.identity) then
      return -- never seen before: observation is off until enabled
    end
    st = state_for(proj)
  end
  if not st or not st.enabled or st.paused then
    return
  end
  if st.handle then
    st.pending = { reason = kind }
    return
  end
  local ocfg = config.get().observer
  arm_timer(st, kind == "save" and ocfg.save_debounce_ms or ocfg.edit_idle_ms, kind)
end

---Register the trigger autocmds (safe to call more than once). Activation
---itself is per project; the autocmds stay cheap and gated on it.
function M.install()
  if installed then
    return
  end
  installed = true
  vim.api.nvim_create_augroup("mentor_observer", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = "mentor_observer",
    callback = function(ev)
      if ev.buf ~= 0 then
        activity(ev.buf, "edit")
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = "mentor_observer",
    callback = function(ev)
      if ev.buf ~= 0 then
        activity(ev.buf, "save")
      end
    end,
  })
  -- Work deferred by Insert mode is reconsidered immediately: held-back
  -- notifications first (scheduled, so typeahead that re-enters Insert mode
  -- keeps them held), then pending passes.
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = "mentor_observer",
    callback = function()
      vim.schedule(function()
        for _, st in pairs(states) do
          flush_deferred(st)
        end
      end)
      for _, st in pairs(states) do
        if st.pending and not running then
          fire(st, st.pending.reason)
        end
      end
    end,
  })
end

---Interactive work preempts background work (observations and
---consolidation). Pending jobs keep their slot and resume afterwards.
---@return integer cancelled operations
function M.preempt()
  local n = 0
  if running then
    cancel_state(running, false)
    n = n + 1
  end
  local ok, consolidate = pcall(require, "mentor.memory.consolidate")
  if ok then
    n = n + consolidate.stop()
  end
  return n
end

---Cancel running observation passes and drop pending jobs (:MentorStop).
---@return integer cancelled
function M.stop()
  local n = 0
  for _, st in pairs(states) do
    if st.handle then
      n = n + 1
    end
    cancel_state(st, true)
  end
  return n
end

-- ---------------------------------------------------------------------------
-- Presentation support

---State snapshot for status display.
function M.status_snapshot(proj)
  proj = proj or project.current()
  if not proj then
    return nil
  end
  local st = states[proj.identity]
  if not st then
    return { enabled = false, paused = false, running = false, pending = false }
  end
  return {
    enabled = st.enabled,
    paused = st.paused,
    running = st.handle ~= nil,
    pending = st.pending ~= nil,
    last_error = st.last_error,
  }
end

function M.activity()
  local out = { running = nil, pending = {} }
  if running then
    out.running = running.identity
  end
  for identity, st in pairs(states) do
    if st.pending then
      out.pending[#out.pending + 1] = identity
    end
  end
  return out
end

---Recompute stored fingerprints so the list shows the truth about staleness.
function M.revalidate_findings(proj)
  proj = proj or project.ensure_current()
  if not proj then
    return
  end
  local st = state_for(proj)
  for _, row in ipairs(records.observations.list_all(st.project_id, 100000)) do
    local fps = row.fingerprints and vim.json.decode(row.fingerprints) or nil
    if type(fps) ~= "table" or next(fps) == nil then
      records.observations.set_stale(row.id, false)
    else
      local current = true
      for _, fp in pairs(fps) do
        if not fingerprint_matches(fp) then
          current = false
          break
        end
      end
      records.observations.set_stale(row.id, not current)
    end
  end
end

---Test seam: simulate an automatic trigger event (edit/save) for a buffer.
M._trigger = activity

---Test seam: drop all in-instance state (persisted rows are untouched).
function M._reset()
  for _, st in pairs(states) do
    if st.timer then
      st.timer:stop()
      if not st.timer:is_closing() then
        st.timer:close()
      end
    end
    if st.handle then
      st.handle:cancel()
    end
  end
  states = {}
  running = nil
  fresh = {}
  insert_probe = mode_is_insert
end

---Test seam: replace the Insert-mode probe (nil restores the real one).
---@param fn (fun(): boolean)|nil
function M._set_insert_probe(fn)
  insert_probe = fn or mode_is_insert
end

-- Internals exposed for deterministic tests.
M._internals = {
  state_for = state_for,
  build_digest = build_digest,
  issue_digest = issue_digest,
  fingerprint_matches = fingerprint_matches,
  may_notify = may_notify,
  is_running = function()
    return running
  end,
}

return M
