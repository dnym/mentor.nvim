-- Unit: project identity — nearest Git root, non-Git
-- fallback, separate worktrees, nested repositories, symlink canonicality.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local config = require("mentor.config")
local project = require("mentor.project")

return function()
  local function fresh(name)
    project.reset()
    config.load({})
    return fs.tmpdir() .. "/" .. name
  end

  H.test("resolves the nearest Git root from a nested directory", function()
    local base = fresh("repo")
    fs.git_repo(base)
    vim.fn.mkdir(base .. "/src/deep", "p")
    local rec = project.for_dir(base .. "/src/deep")
    H.ok(rec and rec.is_git, "git project")
    H.eq(rec.identity, project.canonical(base), "identity is the working-tree root")
  end)

  H.test("symlinked paths canonicalize to the same identity", function()
    local base = fresh("symrepo")
    fs.git_repo(base)
    local link = fs.tmpdir() .. "/link-to-repo"
    vim.uv.fs_symlink(project.canonical(base), link)
    local via_link = project.for_dir(link)
    local direct = project.for_dir(base)
    H.eq(via_link.identity, direct.identity, "same identity through the symlink")
  end)

  H.test("nested repositories are separate projects", function()
    local base = fresh("outer")
    fs.git_repo(base)
    local inner = base .. "/vendor/inner"
    fs.git_repo(inner)
    local outer = project.for_dir(base .. "/src")
    local inner_rec = project.for_dir(inner .. "/lib")
    H.neq(outer.identity, inner_rec.identity, "distinct identities")
    H.eq(inner_rec.identity, project.canonical(inner), "inner resolves to its own root")
    H.ok(project.is_nested_repo(inner, outer.identity), "flagged as nested for traversal (M2)")
    H.ok(not project.is_nested_repo(base, outer.identity), "the root itself is not nested")
  end)

  H.test("worktrees get separate identities but share the common git dir", function()
    local base = fresh("wt-main")
    fs.git_repo(base)
    local wt = fs.tmpdir() .. "/wt-feature"
    fs.git(base, { "worktree", "add", "-q", project.canonical(wt), "HEAD" })
    local main = project.for_dir(base)
    local second = project.for_dir(wt)
    H.neq(main.identity, second.identity, "worktrees are separate projects")
    H.ok(main.git_common_dir and second.git_common_dir, "common dir recorded")
    H.eq(main.git_common_dir, second.git_common_dir, "same repository behind both")
  end)

  H.test("non-Git projects fall back to the anchor or configured root", function()
    local base = fresh("plain")
    local rec = project.for_dir(base .. "/sub/deeper")
    H.ok(not rec.is_git, "not a git project")
    H.eq(rec.identity, project.canonical(base .. "/sub/deeper"), "anchored at the activation directory")

    local configured = fresh("explicit")
    config.load({ projects = { fallback_root = configured } })
    project.reset()
    local rec2 = project.for_dir(base)
    H.eq(rec2.identity, project.canonical(configured), "explicit root wins")
    config.load({})
  end)

  H.test("buffer paths resolve through the same rules", function()
    local base = fresh("bufrepo")
    fs.git_repo(base)
    local file = fs.write(base .. "/pkg/mod.py", "print('hi')\n")
    local buf = vim.fn.bufadd(file)
    local rec = project.for_buf(buf)
    H.eq(rec.identity, project.canonical(base), "buffer resolves to the repository root")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end
