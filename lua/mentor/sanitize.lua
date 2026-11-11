-- Best-effort secret detection and redaction for anything that may reach the
-- model, logs, or storage. Detection uses documented patterns for known
-- credential formats and private-key blocks; it is best effort, not a
-- guarantee. Tests use synthetic secrets.

local M = {}

---Build a Lua pattern that also matches the upper-case form of each letter.
local function ci(text)
  return (text:gsub("%a", function(c)
    return "[" .. c:lower() .. c:upper() .. "]"
  end))
end

---Repeat a character class n times (Lua patterns have no quantifiers).
local function rep(cls, n)
  return cls:rep(n)
end

-- Each entry: kind -> { pattern, replacement } for text.gsub. Function
-- captures keep the named prefix and replace only the value.
M.patterns = {
  {
    kind = "private-key-block",
    pattern = "%-%-%-%-%-BEGIN.-%-%-%-%-%-END.-%-",
    replace = "-----REDACTED PRIVATE KEY BLOCK-----",
  },
  {
    kind = "aws-access-key",
    pattern = "AKIA" .. rep("[0-9A-Z]", 16),
    replace = "AKIA[REDACTED]",
  },
  {
    kind = "openai-style-key",
    pattern = "sk%-" .. rep("[A-Za-z0-9_%-]", 20) .. "[A-Za-z0-9_%-]*",
    replace = "sk-[REDACTED]",
  },
  {
    kind = "github-token",
    pattern = "gh[pousr]_" .. rep("%w", 36) .. "%w*",
    replace = "gh[REDACTED]",
  },
  {
    kind = "slack-token",
    pattern = "xox[baprs]%-" .. rep("[%w%-]", 10) .. "[%w%-]*",
    replace = "xox[REDACTED]",
  },
  {
    kind = "google-api-key",
    pattern = "AIza" .. rep("[%w%-_]", 35) .. "[%w%-_]*",
    replace = "AIza[REDACTED]",
  },
}

-- Generic key=value assignment style; keeps the setting name, drops the
-- value. Lua patterns have no alternation, so one rule per credential-ish
-- name. Deliberately broad — false positives are preferable to leaks.
do
  -- Lua patterns have no counted quantifiers, so the separator and the
  -- minimum-length value are spelled out with repeated classes.
  local optional_space = "[%s\"']?[%s\"']?[%s\"']?"
  local value_class = "[%w_%-%./+=]"
  local function assignment_rule(name_pattern)
    return {
      kind = "credential-assignment",
      pattern = "(" .. name_pattern .. "s?)(" .. optional_space .. "[:=%s][%s\"']?[%s\"']?)(" .. rep(
        value_class,
        8
      ) .. value_class .. "*)",
      replace = function(prefix, sep)
        return prefix .. sep .. "[REDACTED]"
      end,
    }
  end
  local api = ci("api")
  for _, name in ipairs({
    api .. "[_-]?" .. ci("key"), -- api_key, api-key, apikey
    ci("token"),
    ci("secret"),
    ci("passwd"),
    ci("password"),
    ci("credential"),
  }) do
    M.patterns[#M.patterns + 1] = assignment_rule(name)
  end
end

---Redacts detected secrets from text.
---@param text string
---@return string redacted, table[] findings ({kind, count})
function M.sanitize(text)
  if type(text) ~= "string" or text == "" then
    return text, {}
  end
  local findings = {}
  for _, rule in ipairs(M.patterns) do
    local hits = 0
    text = text:gsub(rule.pattern, function(a, b, c)
      hits = hits + 1
      if type(rule.replace) == "function" then
        return rule.replace(a, b, c)
      end
      return rule.replace
    end)
    if hits > 0 then
      findings[#findings + 1] = { kind = rule.kind, count = hits }
    end
  end
  return text, findings
end

---Sanitizes every string inside a result table (in place, recursively).
---Counts redactions across all strings; non-string values pass through.
---@param value any
---@param findings table[] accumulator
---@param depth integer
---@return any sanitized
function M.sanitize_tree(value, findings, depth)
  depth = depth or 0
  if depth > 12 then
    return value
  end
  if type(value) == "string" then
    local clean, found = M.sanitize(value)
    for _, f in ipairs(found) do
      findings[#findings + 1] = f
    end
    return clean
  elseif type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      out[M.sanitize_tree(k, findings, depth + 1)] = M.sanitize_tree(v, findings, depth + 1)
    end
    return out
  end
  return value
end

return M
