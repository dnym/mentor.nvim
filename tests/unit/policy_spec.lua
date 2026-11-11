-- Unit: access policy — exclusion defaults, symlink containment, nested
-- repositories, sibling isolation, external roots, generation tracking.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local config = require("mentor.config")
local project = require("mentor.project")
local policy_mod = require("mentor.policy")

return function()
  local function fresh_repo(label)
    project.reset()
    config.load({})
    local dir = fs.git_repo(fs.tmpdir() .. "/" .. label)
    return dir, project.for_dir(dir)
  end

  H.test("default exclusions block credential files everywhere", function()
    local _, proj = fresh_repo("excl")
    local policy = policy_mod.for_project(proj)
    for _, path in ipairs({
      ".env",
      ".env.production",
      "config/id_ed25519",
      "certs/server.pem",
      "deploy/app.key",
      "home/.git-credentials",
    }) do
      local access, why = policy:authorize(path)
      H.ok(access == nil, path .. " must be denied")
      H.contains_text(why, "excluded", path .. " denial reason")
    end
  end)

  H.test("user exclusions add patterns but cannot re-allow defaults", function()
    local _, proj = fresh_repo("excl2")
    config.load({ context = { exclusions = { "build", "**/generated/**", "src/private" } } })
    local policy = policy_mod.for_project(proj)
    -- user patterns apply
    for _, path in ipairs({
      "build/output.js",
      "src/build/cache.txt",
      "x/generated/y.lua",
      "generated/z.lua",
      "src/private/note.txt",
    }) do
      local access = policy:authorize(path)
      H.ok(access == nil, path .. " excluded by user pattern")
    end
    -- defaults survive user configuration
    H.ok(policy:authorize(".env") == nil, ".env stays excluded")
    H.ok(policy:authorize("src/main.lua") ~= nil, "ordinary paths allowed")
    config.load({})
  end)

  H.test("the .git directory is never reachable through file access", function()
    local _, proj = fresh_repo("gitdir")
    local policy = policy_mod.for_project(proj)
    local access, why = policy:authorize(".git/config")
    H.ok(access == nil, ".git/config denied")
    H.contains_text(why, "Git adapters", "reason points at the adapters")
  end)

  H.test("paths outside the root are denied (sibling projects)", function()
    local _, proj = fresh_repo("home")
    local sibling = fs.git_repo(fs.tmpdir() .. "/sibling-project")
    local policy = policy_mod.for_project(proj)
    local access, why = policy:authorize(sibling .. "/secret.lua")
    H.ok(access == nil, "sibling project path denied")
    H.contains_text(why, "outside", "reason")
    H.ok(policy:authorize("../sibling-project/secret.lua") == nil, "relative escape denied")
  end)

  H.test("symlinks cannot carry access outside the root", function()
    local dir, proj = fresh_repo("sym")
    local outside = fs.tmpdir()
    fs.write(outside .. "/outside-target.lua", "external\n")
    vim.uv.fs_symlink(outside, dir .. "/escape")
    vim.fn.mkdir(dir .. "/internal", 1)
    fs.write(dir .. "/internal/real.lua", "internal\n")
    vim.uv.fs_symlink(dir .. "/internal", dir .. "/mirror")

    local policy = policy_mod.for_project(proj)
    local access, why = policy:authorize("escape/outside-target.lua")
    H.ok(access == nil, "symlink escape denied")
    H.contains_text(why, "outside", "reason")
    -- absolute path through the in-repo symlink is caught as well
    H.ok(policy:authorize(dir .. "/escape/outside-target.lua") == nil, "absolute form also denied")

    local ok_access = policy:authorize("mirror/real.lua")
    H.ok(ok_access ~= nil, "symlink staying inside the root is allowed")
    H.eq(ok_access.rel, "internal/real.lua", "rel path follows the resolved target")
  end)

  H.test("nested repositories are separate projects, denied from the parent", function()
    local dir, proj = fresh_repo("nested")
    fs.git_repo(dir .. "/vendor/inner")
    fs.write(dir .. "/vendor/inner/marker.lua", "inner\n")
    fs.write(dir .. "/vendor/keep.lua", "fine\n")
    local policy = policy_mod.for_project(proj)
    local access, why = policy:authorize("vendor/inner/marker.lua")
    H.ok(access == nil, "nested repo file denied")
    H.contains_text(why, "nested", "reason")
    H.ok(policy:authorize("vendor/keep.lua") ~= nil, "the containing directory itself stays readable")
  end)

  H.test("unsaved named paths that do not exist yet are authorized by scope", function()
    local _, proj = fresh_repo("future")
    local policy = policy_mod.for_project(proj)
    local access = policy:authorize("src/new-unsaved-module.lua")
    H.ok(access ~= nil, "future path allowed")
    H.eq(access.exists, false, "flagged as not on disk")
    H.ok(
      policy:authorize("src/../../outside.lua") == nil,
      "traversal above the root denied even for missing files"
    )
  end)

  H.test("configured external directories gain access, exclusions still apply", function()
    local _, proj = fresh_repo("ext")
    local outside = fs.tmpdir() .. "/shared-libs"
    fs.write(outside .. "/pkg/helper.lua", "helper\n")
    fs.write(outside .. "/.env", "SECRET=x\n")
    config.load({ projects = { external_dirs = { outside } } })
    local policy = policy_mod.for_project(proj)
    local access = policy:authorize(outside .. "/pkg/helper.lua")
    H.ok(access ~= nil, "external file readable")
    H.contains_text(access.rel, "pkg/helper.lua", "relative to the external root")
    H.ok(policy:authorize(outside .. "/.env") == nil, "exclusions apply inside external roots")
    config.load({})
  end)

  H.test("generation increases on configuration reload", function()
    local _, proj = fresh_repo("gen")
    local policy = policy_mod.for_project(proj)
    local before = policy.generation
    config.load({ context = { exclusions = { "tmp" } } })
    H.neq(policy_mod.generation(), before, "generation bumped")
    H.eq(policy.generation, before, "policies keep their creation generation")
    config.load({})
  end)
end
