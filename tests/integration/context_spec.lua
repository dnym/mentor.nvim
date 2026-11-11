-- Integration: context source tracking. Recorded sources must invalidate
-- pending results when buffers change or close, files change on disk, the
-- access policy is reconfigured, or the checkout moves.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local config = require("mentor.config")
local project = require("mentor.project")
local policy_mod = require("mentor.policy")
local context = require("mentor.context")

return function()
  ---Fresh repo + policy. Trackers must be created after config loads:
  ---reloading configuration bumps the policy generation globally.
  local function setup(label)
    project.reset()
    config.load({ data_dir = fs.tmpdir() .. "/data-" .. label })
    local dir = fs.git_repo(fs.tmpdir() .. "/" .. label)
    fs.write(dir .. "/src/mod.lua", "local M = {}\nreturn M\n")
    fs.commit(dir, "add module")
    return dir, policy_mod.for_project(project.for_dir(dir))
  end

  local function kinds(invalidated)
    local out = {}
    for _, item in ipairs(invalidated) do
      out[item.kind] = true
    end
    return out
  end

  H.test("an untouched tracker verifies clean", function()
    local _, policy = setup("clean")
    local tracker = context.new_tracker(policy.project, policy)
    tracker:disk(policy.project.root .. "/src/mod.lua", vim.uv.fs_stat(policy.project.root .. "/src/mod.lua"))
    local ok, invalid = tracker:verify()
    H.ok(ok, "no invalidation")
    H.eq(#invalid, 0, "empty invalidation list")
  end)

  H.test("buffer edits and closes invalidate recorded buffer sources", function()
    local dir, policy = setup("bufedit")
    local buf = vim.fn.bufadd(dir .. "/src/mod.lua")
    vim.fn.bufload(buf)
    local tracker = context.new_tracker(policy.project, policy)
    tracker:buffer(buf)

    local ok = tracker:verify()
    H.ok(ok, "clean before the edit")

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- edited, unsaved" })
    ok = tracker:verify()
    H.ok(not ok, "edit invalidates")
    local found = kinds(select(2, tracker:verify())).buffer
    H.ok(found, "buffer kind reported")

    vim.api.nvim_buf_delete(buf, { force = true })
    local fresh = context.new_tracker(policy.project, policy)
    H.ok(select(1, fresh:verify()), "a tracker that never used the buffer is unaffected")
  end)

  H.test("disk changes invalidate recorded file sources", function()
    local dir, policy = setup("diskchange")
    local path = dir .. "/src/mod.lua"
    local tracker = context.new_tracker(policy.project, policy)
    tracker:disk(path, vim.uv.fs_stat(path))
    H.ok(select(1, tracker:verify()), "clean before the change")

    fs.write(path, "local M = {}\n-- externally modified\nreturn M\n")
    local ok, invalid = tracker:verify()
    H.ok(not ok, "disk change invalidates")
    H.ok(kinds(invalid).disk, "disk kind reported")

    local other = context.new_tracker(policy.project, policy)
    other:disk(dir .. "/unrelated.lua", nil) -- missing stat must not crash
    H.ok(select(1, other:verify()), "no bogus source recorded")
  end)

  H.test("reloading configuration invalidates context captured under the old policy", function()
    local dir, policy = setup("policychange")
    local tracker = context.new_tracker(policy.project, policy)
    tracker:disk(dir .. "/src/mod.lua", vim.uv.fs_stat(dir .. "/src/mod.lua"))
    H.ok(select(1, tracker:verify()), "clean before the reload")

    config.load({ context = { exclusions = { "docs" } } })
    local ok, invalid = tracker:verify()
    H.ok(not ok, "policy change invalidates")
    H.ok(kinds(invalid).policy, "policy kind reported")
    config.load({})
  end)

  H.test("a checkout change invalidates recorded work", function()
    local dir, policy = setup("checkout")
    local tracker = context.new_tracker(policy.project, policy)
    tracker:record_checkout()
    H.ok(tracker.checkout ~= nil, "checkout recorded")
    H.ok(select(1, tracker:verify()), "clean before the commit")

    fs.write(dir .. "/src/later.lua", "return 2\n")
    fs.commit(dir, "new commit moves HEAD")
    local ok, invalid = tracker:verify()
    H.ok(not ok, "checkout change invalidates")
    H.ok(kinds(invalid).checkout, "checkout kind reported")
  end)

  H.test("source list covers buffers and disk files for provenance display", function()
    local dir, policy = setup("srclist")
    local buf = vim.fn.bufadd(dir .. "/src/mod.lua")
    vim.fn.bufload(buf)
    local tracker = context.new_tracker(policy.project, policy)
    tracker:buffer(buf)
    tracker:disk(dir .. "/src/mod.lua", vim.uv.fs_stat(dir .. "/src/mod.lua"))

    local list = tracker:sources_list()
    local saw_buf, saw_disk = false, false
    for _, src in ipairs(list) do
      if src.kind == "buffer" then
        saw_buf = true
        H.contains_text(src.name, "src/mod.lua", "buffer provenance names the file")
      elseif src.kind == "disk" then
        saw_disk = true
      end
    end
    H.ok(saw_buf and saw_disk, "both source kinds listed")
  end)

  H.test("same_project separates buffers by canonical project identity", function()
    local dir, policy = setup("sameproj")
    local tracker = context.new_tracker(policy.project, policy)
    local own = vim.fn.bufadd(dir .. "/src/mod.lua")
    local sibling_dir = fs.git_repo(fs.tmpdir() .. "/sibling-ctx")
    local foreign = vim.fn.bufadd(sibling_dir .. "/foreign.lua")
    H.ok(tracker:same_project(own), "own-project buffer accepted")
    H.ok(not tracker:same_project(foreign), "sibling-project buffer rejected")
  end)
end
