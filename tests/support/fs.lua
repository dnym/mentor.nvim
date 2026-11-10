-- Temporary workspaces and constrained Git helpers for checks. Deterministic
-- Linux environment only (per the verification strategy).

local M = {}

local tmp_roots = {}

function M.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  tmp_roots[#tmp_roots + 1] = dir
  return dir
end

function M.write(path, contents)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(contents, "\n", { plain = true }), path)
  return path
end

---Runs git with fixed arguments; test workspaces are disposable.
function M.git(cwd, args)
  local argv = { "git", "-C", cwd }
  vim.list_extend(argv, args)
  local out = vim.system(argv, { text = true, timeout = 10000 }):wait()
  assert(out.code == 0, "git " .. table.concat(args, " ") .. " failed: " .. (out.stderr or ""))
  return vim.trim(out.stdout or "")
end

---Creates a throwaway git repository with one commit.
function M.git_repo(dir)
  vim.fn.mkdir(dir, "p")
  M.git(dir, { "init", "-q", "-b", "main" })
  M.git(dir, {
    "-c",
    "user.name=Test",
    "-c",
    "user.email=test@example.invalid",
    "commit",
    "-q",
    "--allow-empty",
    "-m",
    "initial",
  })
  return dir
end

function M.cleanup()
  for _, dir in ipairs(tmp_roots) do
    local ok, proc = pcall(vim.system, { "rm", "-rf", dir })
    if ok then
      proc:wait(10000)
    end
  end
  tmp_roots = {}
end

return M
