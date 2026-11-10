-- Tiny deterministic test harness (no external dependencies).

local H = { passed = 0, failed = 0, failures = {} }

---@param name string
---@param fn fun()
function H.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    H.passed = H.passed + 1
    io.write("  ok   " .. name .. "\n")
  else
    H.failed = H.failed + 1
    H.failures[#H.failures + 1] = name .. ": " .. tostring(err)
    io.write("  FAIL " .. name .. "\n")
    io.write("       " .. tostring(err) .. "\n")
  end
end

function H.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format("%s: expected %s, got %s", msg or "value", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

function H.neq(actual, unexpected, msg)
  if vim.deep_equal(actual, unexpected) then
    error(string.format("%s: expected value different from %s", msg or "value", vim.inspect(unexpected)), 2)
  end
end

function H.ok(value, msg)
  if not value then
    error((msg or "assertion") .. ": got " .. vim.inspect(value), 2)
  end
end

---Asserts fn errors with a message containing the literal needle.
function H.expect_error(fn, needle, msg)
  local ok, err = pcall(fn)
  if ok then
    error(
      (msg or "expected error") .. ": call succeeded but should have failed (needle: " .. needle .. ")",
      2
    )
  end
  if not tostring(err):find(needle, 1, true) then
    error((msg or "expected error") .. ": message " .. tostring(err) .. " lacks " .. needle, 2)
  end
  return tostring(err)
end

function H.contains_text(haystack, needle, msg)
  if not tostring(haystack):find(needle, 1, true) then
    error((msg or "text search") .. ": " .. vim.inspect(haystack) .. " lacks " .. needle, 2)
  end
end

function H.summary()
  io.write(string.format("\n%d passed, %d failed\n", H.passed, H.failed))
  if H.failed > 0 then
    io.write("Failures:\n")
    for _, f in ipairs(H.failures) do
      io.write("  - " .. f .. "\n")
    end
    vim.cmd("cquit 1")
  end
end

return H
