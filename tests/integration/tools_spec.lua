-- Integration: the read-only investigation tools. Covers buffer precedence
-- (including unsaved named buffers), exclusions and boundaries, schema
-- validation, sanitization of returned content, and the milestone
-- completion scenario: a fake model investigates an unsaved cross-file edit
-- while excluded files, sibling projects, nested repositories, and external
-- symlink targets remain inaccessible — with no project file written.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local config = require("mentor.config")
local project = require("mentor.project")
local tools = require("mentor.tools")

return function()
  local sandbox

  ---Builds a fresh repository fixture and an operation context for it.
  local function setup(label, overrides)
    project.reset()
    config.load(vim.tbl_extend("force", {
      data_dir = fs.tmpdir() .. "/data-" .. label,
      context = { max_file_bytes = 4096 },
    }, overrides or {}))
    sandbox = fs.git_repo(fs.tmpdir() .. "/" .. label)

    fs.write(
      sandbox .. "/src/app.lua",
      "local util = require('util')\nlocal total = util.compute_total({1, 2})\n"
    )
    fs.write(sandbox .. "/src/util.lua", table.concat({
      "local M = {}",
      "function M.compute_total(items)",
      "  local sum = 0",
      "  for _, v in ipairs(items) do sum = sum + v end",
      "  return sum",
      "end",
      "return M",
    }, "\n") .. "\n")
    fs.write(sandbox .. "/notes/readme.md", "scratchpad\n")
    fs.write(sandbox .. "/.env", "SUPER_SECRET=credential-never-leaks\n")
    fs.write(sandbox .. "/config/settings.lua", "api_key = fake-but-synthetic-secret-9999\n")

    -- nested repository (separate project, must stay out of parent scope)
    fs.git_repo(sandbox .. "/vendor/inner")
    fs.write(sandbox .. "/vendor/inner/marker.lua", "NESTED-REPO-CONTENT\n")

    -- sibling project outside this root
    local sibling = fs.git_repo(fs.tmpdir() .. "/sibling-" .. label)
    fs.write(sibling .. "/app.lua", "SIBLING-PROJECT-CONTENT\n")

    -- external symlink target inside the repo tree
    local outside = fs.tmpdir()
    fs.write(outside .. "/escape-target.lua", "EXTERNAL-SYMLINK-CONTENT\n")
    vim.uv.fs_symlink(outside, sandbox .. "/escape")

    -- binary file (written via libuv: NUL bytes stay data, not VimL Blob)
    vim.fn.mkdir(sandbox .. "/assets", "p")
    local binfd = vim.uv.fs_open(sandbox .. "/assets/blob.bin", "w", 420)
    vim.uv.fs_write(binfd, "head\0tail\n\1\1garbage\n", 0)
    vim.uv.fs_close(binfd)

    fs.commit(sandbox, "baseline")
    return project.for_dir(sandbox)
  end

  local function ctx_for(proj)
    return tools.new_operation({ project = proj })
  end

  ---Fingerprint of every repository working-tree file (for the no-writes
  ---assertion). .git internals are excluded: git may refresh its own index,
  ---which is not a project file write.
  local function fingerprint(dir)
    local out = {}
    local probe = vim
      .system({ "find", dir, "-type", "f", "-not", "-path", "*/.git/*", "-printf", "%p %s %T@\n" }, { text = true })
      :wait()
    for line in (probe.stdout or ""):gmatch("[^\n]+") do
      out[#out + 1] = line
    end
    table.sort(out)
    return table.concat(out, "\n")
  end

  H.test("buffer contents take precedence, including unsaved named buffers", function()
    local proj = setup("buffers")
    -- edit an existing file's buffer without writing
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/src/app.lua"))
    vim.api.nvim_buf_set_lines(
      0,
      0,
      -1,
      false,
      { "local total = util.compute_total({1, 2, 3}) -- UNCOMMITTED-EDIT" }
    )

    -- unsaved named buffer that does not exist on disk
    local newbuf = vim.fn.bufadd(proj.root .. "/src/newmodule.lua")
    vim.api.nvim_buf_set_lines(newbuf, 0, -1, false, { "-- NEW-MODULE scratch design" })

    local ctx = ctx_for(proj)
    local res = tools.run(ctx, "read_file", { path = "src/app.lua" })
    H.ok(res.ok, "read ok")
    H.eq(res.source, "buffer", "buffer content wins")
    H.contains_text(res.content, "UNCOMMITTED-EDIT", "unsaved content served")
    H.eq(res.unsaved, true, "flagged unsaved")

    local res2 = tools.run(ctx, "read_file", { path = "src/newmodule.lua" })
    H.ok(res2.ok, "unsaved named buffer readable even with no disk file")
    H.contains_text(res2.content, "NEW-MODULE", "unsaved named content served")

    local buf_res = tools.run(ctx, "get_buffer", { path = "src/newmodule.lua" })
    H.ok(buf_res.ok, "get_buffer by path")
    H.eq(buf_res.bufnr, newbuf, "resolved buffer")
    H.eq(buf_res.modified, true, "modified reported")
  end)

  H.test("content search sees unsaved edits and respects exclusions", function()
    local proj = setup("search")
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/src/app.lua"))
    vim.api.nvim_buf_set_lines(
      0,
      0,
      -1,
      false,
      { "local total = util.compute_total({1, 2, 3}) -- UNCOMMITTED-EDIT" }
    )

    local ctx = ctx_for(proj)
    local res = tools.run(ctx, "search_content", { query = "compute_total" })
    H.ok(res.ok, "search ok")
    local found_buffer, found_disk = false, false
    for _, m in ipairs(res.matches) do
      if m.path == "src/app.lua" and m.unsaved then
        found_buffer = true
      end
      if m.path == "src/util.lua" then
        found_disk = true
      end
    end
    H.ok(found_buffer, "unsaved buffer edit found")
    H.ok(found_disk, "disk file found")

    -- content that only exists in excluded material is never surfaced
    for _, needle in ipairs({ "SUPER_SECRET", "NESTED-REPO-CONTENT", "EXTERNAL-SYMLINK-CONTENT" }) do
      local denied = tools.run(ctx, "search_content", { query = needle })
      H.eq(#denied.matches, 0, needle .. " not surfaced through search")
    end
    H.ok(res.skipped.excluded > 0, "excluded files counted as skipped")

    -- binary files are skipped explicitly, not searched
    local bin = tools.run(ctx, "read_file", { path = "assets/blob.bin" })
    H.ok(bin.binary and bin.skipped, "binary read skipped with explicit result")
  end)

  H.test("list and path search skip exclusions", function()
    local proj = setup("listing")
    local ctx = ctx_for(proj)
    local res = tools.run(ctx, "list_directory", {})
    H.ok(res.ok, "list ok")
    local names = {}
    for _, e in ipairs(res.entries) do
      names[e.name] = true
    end
    H.ok(names["src"] and names["vendor"], "ordinary entries listed")
    H.ok(
      not names[".env"] and not names[".git"] and not names["escape"],
      "excluded and symlink entries hidden"
    )
    H.ok(res.skipped.excluded >= 2 and res.skipped.symlinks >= 1, "skips counted")

    local inner = tools.run(ctx, "list_directory", { path = "vendor" })
    H.ok(inner.ok, "vendor listable")
    H.eq(inner.skipped.nested_repos, 1, "nested repository hidden")

    local paths = tools.run(ctx, "search_files", { pattern = "*.lua" })
    H.ok(paths.ok, "glob search ok")
    for _, m in ipairs(paths.matches) do
      H.ok(
        not m.rel:find(".env", 1, true) and not m.rel:find("inner/", 1, true),
        "no excluded path in " .. m.rel
      )
    end
    local sub = tools.run(ctx, "search_files", { pattern = "util" })
    local hit = false
    for _, m in ipairs(sub.matches) do
      hit = hit or m.rel == "src/util.lua"
    end
    H.ok(hit, "substring path search finds the file")
  end)

  H.test("denials are actionable for excluded, nested, sibling, and symlink targets", function()
    local proj = setup("denials")
    local ctx = ctx_for(proj)
    local cases = {
      { ".env", "excluded" },
      { "vendor/inner/marker.lua", "nested" },
      { "escape/escape-target.lua", "outside" },
      { (proj.root):gsub("/*$", "") .. "/../sibling-denials/app.lua", "outside" },
    }
    for _, case in ipairs(cases) do
      local res = tools.run(ctx, "read_file", { path = case[1] })
      H.ok(not res.ok, case[1] .. " denied")
      H.contains_text(res.error, case[2], "actionable reason for " .. case[1])
    end
  end)

  H.test("tool requests are validated against their schemas", function()
    local proj = setup("schema")
    local ctx = ctx_for(proj)

    local unknown = tools.run(ctx, "execute_command", { cmd = "ls" })
    H.ok(not unknown.ok, "unknown tool rejected")
    H.contains_text(unknown.error, "available:", "available tools listed")

    local missing = tools.run(ctx, "read_file", {})
    H.ok(not missing.ok, "missing parameter rejected")
    H.contains_text(missing.error, "missing required parameter path", "named parameter")

    local wrong_type = tools.run(ctx, "read_file", { path = 123 })
    H.ok(not wrong_type.ok, "wrong type rejected")

    local extra = tools.run(ctx, "read_file", { path = "src/app.lua", force = true })
    H.ok(not extra.ok, "unknown parameter rejected rather than ignored")
    H.contains_text(extra.error, "unknown parameter force", "named parameter")
  end)

  H.test("no investigation tool writes to project files", function()
    local proj = setup("writes")
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/src/util.lua"))
    local before = fingerprint(proj.root)

    local ctx = ctx_for(proj)
    local calls = {
      { "list_directory", {} },
      { "search_content", { query = "compute" } },
      { "search_files", { pattern = "util" } },
      { "read_file", { path = "src/util.lua" } },
      { "get_git_status", {} },
      { "get_git_diff", {} },
      { "get_git_history", {} },
      { "get_diagnostics", {} },
    }
    for _, call in ipairs(calls) do
      local res = tools.run(ctx, call[1], call[2])
      H.ok(res.ok or res.available ~= nil, call[1] .. " executed without failure")
    end
    H.eq(fingerprint(proj.root), before, "no repository file created, modified, or removed")
    vim.cmd("silent! bdelete! " .. vim.fn.bufnr(proj.root .. "/src/util.lua"))
  end)

  H.test("the model never controls commands: odd path arguments stay literal data", function()
    local proj = setup("argv")
    local ctx = ctx_for(proj)
    local sneaky = "src/app.lua; rm -rf /"
    local res = tools.run(ctx, "read_file", { path = sneaky })
    H.ok(not res.ok, "path-like garbage is a failed lookup, not a command")
    local shellish = "$(whoami)"
    local res2 = tools.run(ctx, "search_files", { pattern = shellish })
    H.ok(res2.ok, "search treats the argument as a literal string")
    H.eq(#res2.matches, 0, "no matches, nothing executed")
  end)

  H.test("returned content is sanitized for secrets", function()
    local proj = setup("sanitize")
    local ctx = ctx_for(proj)
    local res = tools.run(ctx, "read_file", { path = "config/settings.lua" })
    H.ok(res.ok, "read ok")
    H.ok(not res.content:find("fake-but-synthetic-secret-9999", 1, true), "credential value withheld")
    H.contains_text(res.content, "REDACTED", "marker present")
    H.ok(res.redacted and #res.redacted > 0, "redaction findings attached")
  end)

  H.test("Git adapters report constrained views and filter excluded paths", function()
    local proj = setup("git")
    fs.write(
      proj.root .. "/src/app.lua",
      "local util = require('util')\nlocal total = util.compute_total({1, 2})\n-- LOCAL-MODIFICATION\n"
    )
    fs.write(proj.root .. "/.env", "SUPER_SECRET=changed-but-excluded\n")
    local ctx = ctx_for(proj)

    local status = tools.run(ctx, "get_git_status", {})
    H.ok(status.ok, "status ok")
    local saw_app, saw_env = false, false
    for _, e in ipairs(status.entries) do
      if e.path == "src/app.lua" then
        saw_app = true
      end
      if e.path == ".env" then
        saw_env = true
      end
    end
    H.ok(saw_app, "modified file reported")
    H.ok(not saw_env, "excluded path filtered from status")
    H.ok(status.filtered_excluded >= 1, "filtering counted")
    H.contains_text(status.view, "disk/index", "view labeled")

    local diff = tools.run(ctx, "get_git_diff", { path = "src/app.lua" })
    H.ok(diff.ok, "diff ok")
    H.contains_text(diff.diff, "LOCAL-MODIFICATION", "diff content available")

    local history = tools.run(ctx, "get_git_history", { limit = 5 })
    H.ok(history.ok, "history ok")
    H.ok(#history.commits >= 1, "commits present")
    H.contains_text(history.commits[1].sha:sub(1, 7), history.commits[1].sha:sub(1, 7), "sha present")

    -- non-Git projects report the adapters as unavailable rather than failing
    local plain = fs.tmpdir() .. "/plain-nogit"
    fs.write(plain .. "/src/file.lua", "return 1\n")
    local plain_ctx = ctx_for(project.for_dir(plain))
    local nogit = tools.run(plain_ctx, "get_git_status", {})
    H.ok(not nogit.ok, "git status unavailable outside a repository")
    H.eq(nogit.available, false, "explicit unavailable flag")
  end)

  H.test("language adapters degrade explicitly without language tooling", function()
    local proj = setup("lang")
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/src/app.lua"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "local function helper() return 41 end",
      "return helper() + 1 -- HELPER-DEFINITION-HERE",
    })
    local ctx = ctx_for(proj)

    local diag = tools.run(ctx, "get_diagnostics", { path = "src/app.lua" })
    H.ok(diag.ok and diag.available, "diagnostics available (possibly empty)")
    H.contains_text(diag.freshness, "unknown", "freshness stated honestly")

    local sym = tools.run(ctx, "find_symbol", { path = "src/app.lua", symbol = "helper" })
    H.ok(sym.available == false, "symbol lookup explicitly unavailable without a language server")
    H.contains_text(sym.reason, "language server", "reason")
    H.contains_text(sym.alternative, "search_content", "alternative offered")
    local refs = tools.run(ctx, "find_references", { path = "src/app.lua", symbol = "helper" })
    H.ok(refs.available == false, "references degrade the same way")
  end)

  H.test("buffers from another project are refused", function()
    local proj = setup("crossbuf")
    local other_dir = fs.git_repo(fs.tmpdir() .. "/other-repo")
    local other_buf = vim.fn.bufadd(other_dir .. "/foreign.lua")
    vim.fn.bufload(other_buf)
    vim.api.nvim_buf_set_lines(other_buf, 0, -1, false, { "FOREIGN-BUFFER" })
    local ctx = ctx_for(proj)
    local res = tools.run(ctx, "get_buffer", { bufnr = other_buf })
    H.ok(not res.ok, "foreign buffer refused")
    H.contains_text(res.error, "different project", "reason")
  end)

  H.test("size limits produce actionable oversized-file results", function()
    local proj = setup("sizes")
    fs.write(proj.root .. "/src/huge.lua", string.rep("-- filler line for the size limit test\n", 200))
    local ctx = ctx_for(proj)
    local res = tools.run(ctx, "read_file", { path = "src/huge.lua" })
    H.ok(not res.ok, "oversized read refused")
    H.contains_text(res.error, "max_file_bytes", "names the limit")
    local search = tools.run(ctx, "search_content", { query = "filler line" })
    H.ok(search.ok, "search survives the large file")
    H.ok(search.skipped.too_large >= 1, "large file counted in skips")
  end)

  -- Milestone completion scenario: a fake model investigates an unsaved
  -- cross-file edit; excluded material and out-of-project targets remain
  -- inaccessible, and nothing writes to the project.
  H.test("completion: fake model investigates an unsaved cross-file edit", function()
    local proj = setup("ac08")
    -- The developer edits app.lua (unsaved) referencing a helper in util.lua.
    vim.cmd("silent! edit " .. vim.fn.fnameescape(proj.root .. "/src/app.lua"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "local util = require('util')",
      "local total = util.compute_total({1, 2}) + util.compute_total -- NEW-PARTIAL-EDIT",
    })

    local before = fingerprint(proj.root)
    local ctx = ctx_for(proj)

    -- Scripted "model" tool calls; each is checked as the dispatcher would.
    local calls = {
      { "get_buffer", { path = "src/app.lua" } },
      { "search_content", { query = "compute_total" } },
      { "read_file", { path = "src/util.lua" } },
      { "get_git_status", {} },
      { "read_file", { path = ".env" } },
      { "read_file", { path = "vendor/inner/marker.lua" } },
      { "read_file", { path = "escape/escape-target.lua" } },
      { "get_buffer", { path = "src/newfile-never-created.lua" } },
    }
    local results = {}
    for _, call in ipairs(calls) do
      results[#results + 1] = tools.run(ctx, call[1], call[2])
    end

    H.ok(results[1].ok and results[1].content:find("NEW-PARTIAL-EDIT", 1, true), "unsaved edit visible")
    H.ok(#results[2].matches >= 2, "cross-file occurrences found")
    H.ok(results[3].ok and results[3].content:find("compute_total", 1, true), "related file readable")
    H.ok(results[4].ok, "git status usable")
    for i = 5, 7 do
      H.ok(not results[i].ok, "call " .. i .. " denied")
    end
    H.ok(not results[8].ok, "never-created path without a buffer refused")

    -- every used source is tracked for later invalidation checks
    local list = ctx.tracker:sources_list()
    local saw_app, saw_util = false, false
    for _, src in ipairs(list) do
      if (src.path or src.name or ""):find("src/app.lua", 1, true) then
        saw_app = true
      end
      if (src.path or ""):find("src/util.lua", 1, true) then
        saw_util = true
      end
    end
    H.ok(saw_app, "buffer source recorded")
    H.ok(saw_util, "disk source recorded")

    -- and investigation used no model-controlled execution and wrote nothing
    H.eq(fingerprint(proj.root), before, "no project writes")
    local up_to_date = ctx.tracker:verify()
    H.ok(up_to_date, "dependencies still consistent immediately after")
  end)
end
