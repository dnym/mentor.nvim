-- Integration: the Markdown memory view. Covers rendering, the save-time
-- diff (edits, deletions via removed blocks, creations via '## [new]'
-- blocks), user-edit protection, conflict handling that keeps the buffer's
-- proposed text untouched, and regeneration of open views after command
-- changes. No network.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local mentor = require("mentor")
local project = require("mentor.project")
local storage = require("mentor.storage")
local records = require("mentor.storage.records")
local memory = require("mentor.memory")
local view = require("mentor.ui.memory")

return function()
  local function configure(label)
    project.reset()
    mentor.shutdown()
    storage.close()
    mentor.setup({ data_dir = fs.tmpdir() .. "/data-mv-" .. label })
    local dir = fs.git_repo(fs.tmpdir() .. "/mv-" .. label)
    fs.write(dir .. "/main.lua", "print('work in progress')\n")
    vim.cmd("silent! edit " .. vim.fn.fnameescape(dir .. "/main.lua"))
    return project.current()
  end

  local function view_text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  local function write_view(buf)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)
  end

  H.test("the view renders entries with stable ids, revisions, and metadata", function()
    local proj = configure("render")
    local one = memory.remember({
      scope = "project",
      project = proj,
      summary = "First entry",
      content = "first body line",
      category = "decision",
      refs = { "main.lua" },
      author = "agent",
    })
    memory.remember({ scope = "global", summary = "Global preference", author = "agent" })

    local buf = view.open()
    H.ok(buf and vim.api.nvim_buf_is_valid(buf), "view buffer opened")
    H.contains_text(vim.api.nvim_buf_get_name(buf), "mentor://memory/", "generated buffer name")
    H.eq(vim.bo[buf].buftype, "acwrite", "generated view, never a disk file")
    H.eq(vim.b[buf].mentor_project, proj.identity, "project binding")
    local text = view_text(buf)
    H.contains_text(text, "## [m" .. one.entry.id .. "] r1", "stable id and revision header")
    H.contains_text(text, "First entry", "summary body")
    H.contains_text(text, "Refs: main.lua", "provenance line")
    H.contains_text(text, "# Global memory", "global section")
    H.contains_text(text, "# Project memory", "project section")
    H.eq(vim.bo[buf].modified, false, "renders clean")
  end)

  H.test("saving commits edits, creations, and block deletions in one pass", function()
    local proj = configure("save")
    local one = memory.remember({
      scope = "project",
      project = proj,
      summary = "First entry",
      content = "first body line",
      author = "agent",
    })
    local two = memory.remember({
      scope = "project",
      project = proj,
      summary = "Second entry",
      content = "doomed content",
      author = "agent",
    })
    local buf = view.open()

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local out = {}
    local skipping = false
    for _, line in ipairs(lines) do
      if line:match("^## %[m" .. two.entry.id .. "%]") then
        skipping = true
      elseif line:match("^## %[m") then
        skipping = false
      end
      if not skipping then
        if line == "First entry" then
          out[#out + 1] = "First entry (edited)"
        elseif line == "first body line" then
          out[#out + 1] = "improved body text"
        else
          out[#out + 1] = line
        end
      end
    end
    -- A creation block under the project section.
    out[#out + 1] = "## [new] · project · note · established"
    out[#out + 1] = "Brand new note"
    out[#out + 1] = "written straight in the view"
    out[#out + 1] = "Refs: main.lua, retry philosophy"
    out[#out + 1] = ""
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)

    write_view(buf)

    local e1 = memory.get(one.entry.id)
    H.eq(e1.summary, "First entry (edited)", "edit committed")
    H.eq(e1.content, "improved body text", "content committed")
    H.eq(e1.revision, 2, "revision bumped")
    H.ok(e1.protected, "user view edit protects the entry")
    H.eq(memory.get(two.entry.id).status, "deleted", "removed block deletes")
    local found
    for _, e in ipairs(memory.visible(proj)) do
      if e.summary == "Brand new note" then
        found = e
      end
    end
    H.ok(found, "creation block committed")
    H.eq(found.uncertainty, "established", "block metadata honored")
    H.eq(found.refs, { "main.lua", "retry philosophy" }, "refs line parsed")
    H.ok(found.protected, "created via view is user-protected")

    local text = view_text(buf)
    H.contains_text(text, "First entry (edited)", "view regenerated from the database")
    H.ok(not text:find("Second entry", 1, true), "deleted entry left the view")
    H.contains_text(text, "## [m" .. found.id .. "] r1", "new entry got a real id")
    H.eq(vim.bo[buf].modified, false, "clean after save")
  end)

  H.test("a stale save is refused entirely and keeps the proposed text", function()
    local proj = configure("conflict")
    local one = memory.remember({
      scope = "project",
      project = proj,
      summary = "First entry",
      content = "original",
      author = "agent",
    })

    local buf = view.open()

    -- Another Neovim instance writes first (repository path + history).
    records.memory.update(one.entry.id, 1, {
      category = "note",
      summary = "First entry",
      content = "written elsewhere",
      uncertainty = "hypothesis",
      refs = nil,
    }, "user", "edited elsewhere")
    records.memory.append_revision(one.entry.id, 2, {
      category = "note",
      summary = "First entry",
      content = "written elsewhere",
      uncertainty = "hypothesis",
      refs = nil,
    }, "user", "edited elsewhere")

    -- Our view still shows r1; edit and try to save.
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
      if line == "original" then
        lines[i] = "our proposed text"
      end
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    write_view(buf)

    H.eq(memory.get(one.entry.id).content, "written elsewhere", "stale save changed nothing in storage")
    H.eq(memory.get(one.entry.id).revision, 2, "no revision bump from the refused save")
    H.contains_text(view_text(buf), "our proposed text", "buffer keeps the user's proposed text")
    H.eq(vim.bo[buf].modified, true, "buffer stays modified for the user to reconcile")
  end)

  H.test("command changes regenerate an open unmodified view", function()
    local proj = configure("regen")
    local one = memory.remember({
      scope = "project",
      project = proj,
      summary = "Will be deleted via command",
      author = "agent",
    })
    local buf = view.open()
    H.contains_text(view_text(buf), "Will be deleted via command", "entry rendered")

    vim.cmd("MentorMemory delete " .. one.entry.id)

    H.eq(memory.get(one.entry.id).status, "deleted", "command deleted the entry")
    H.ok(not view_text(buf):find("Will be deleted via command", 1, true), "open view regenerated")
  end)

  H.test("views closed with :bdelete reopen fully set up", function()
    local proj = configure("bdelete")
    memory.remember({ scope = "project", project = proj, summary = "Survives bdelete", author = "agent" })
    local buf = view.open()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("bdelete")
    end)
    vim.wait(50, function()
      return not vim.api.nvim_buf_is_valid(buf)
    end, 5)
    local again = view.open()
    H.eq(vim.bo[again].buftype, "acwrite", "memory view keeps its write handler type")
    H.eq(vim.b[again].mentor_project, proj.identity, "memory view binding")
    H.contains_text(view_text(again), "Survives bdelete", "memory view re-rendered")

    -- The observations list maps q to :bdelete; reopening must restore it.
    local obs = require("mentor.ui.observations")
    H.ok(obs.open(), "observations opened")
    local obuf = vim.api.nvim_get_current_buf()
    vim.cmd("normal q")
    vim.wait(50, function()
      return not vim.api.nvim_buf_is_valid(obuf)
    end, 5)
    H.ok(obs.open(), "observations reopened")
    local nbuf = vim.api.nvim_get_current_buf()
    H.eq(vim.b[nbuf].mentor_project, proj.identity, "observations binding")
    H.ok(vim.fn.maparg("d", "n", false, true).buffer == 1, "observation keymaps restored")
  end)
end
