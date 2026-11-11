-- Unit: secret detection and redaction. Synthetic secrets only; ordinary
-- code and text must pass through unchanged.

local H = require("tests.support.harness")
local sanitize = require("mentor.sanitize")

return function()
  local function redacts(text, expect_finding)
    local clean, findings = sanitize.sanitize(text)
    H.ok(not clean:find(text, 1, true) or #findings > 0, "expected a redaction in: " .. text)
    H.ok(clean:find("REDACTED", 1, true) ~= nil, "redaction marker present for: " .. text)
    if expect_finding then
      local kinds = {}
      for _, f in ipairs(findings) do
        kinds[f.kind] = f.count
      end
      H.ok(kinds[expect_finding] and kinds[expect_finding] > 0, "finding kind " .. expect_finding)
    end
    return clean
  end

  H.test("private key blocks are redacted", function()
    local text = table.concat({
      "id_rsa.pub text before",
      "-----BEGIN OPENSSH PRIVATE KEY-----",
      "b3BlbnNzaC1rZXktdjEAAAAA-SYNTHETIC-BLOB",
      "-----END OPENSSH PRIVATE KEY-----",
      "text after",
    }, "\n")
    local clean = redacts(text, "private-key-block")
    H.ok(not clean:find("SYNTHETIC-BLOB", 1, true), "key material removed")
  end)

  H.test("known credential formats are redacted", function()
    redacts("key AKIA" .. ("A1B2"):rep(4) .. " trailing", "aws-access-key")
    redacts("export KEY=sk-" .. ("abcdef0123"):rep(3) .. "123", "openai-style-key")
    redacts("token ghp_" .. ("x"):rep(36) .. "!", "github-token")
    redacts("hook xoxb-" .. ("1234567890ab"):rep(2), "slack-token")
    redacts("AIza" .. ("Qq9-"):rep(9) .. "xy", "google-api-key")
  end)

  H.test("generic credential assignments keep the name and drop the value", function()
    local clean = redacts("api_key = super-secret-value-12345", "credential-assignment")
    H.contains_text(clean, "api_key", "setting name preserved")
    H.ok(not clean:find("super-secret-value-12345", 1, true), "value removed")
    redacts("db.password: hunter2hunter2", "credential-assignment")
    redacts("TOKEN = 'abcdefghij1234'", "credential-assignment")
  end)

  H.test("ordinary code and prose are untouched", function()
    local samples = {
      "local function compute_total(items) return items.count * items.price end",
      "The password policy rotates quarterly; see handbook.",
      "keys = { name = 'id', value = 'short' } -- schema documentation",
      "secretary = team.lead -- a person, not a credential",
    }
    for _, sample in ipairs(samples) do
      local clean, findings = sanitize.sanitize(sample)
      H.eq(clean, sample, "unchanged: " .. sample)
      H.eq(#findings, 0, "no findings for: " .. sample)
    end
  end)

  H.test("sanitize_tree walks nested tables including string keys", function()
    local findings = {}
    local dirty = {
      content = "password: leakedvalue999",
      meta = { author = "dev", nested = { "AKIA" .. ("ZZZZ"):rep(4), 42, true } },
    }
    local clean = sanitize.sanitize_tree(dirty, findings)
    H.ok(not clean.content:find("leakedvalue999", 1, true), "nested string sanitized")
    local joined = vim.inspect(clean)
    H.ok(not joined:find("AKIAZZZZ", 1, true), "array entries sanitized")
    H.ok(#findings >= 2, "findings accumulated across the tree")
    H.eq(clean.meta.nested[2], 42, "numbers pass through")
    H.eq(clean.meta.nested[3], true, "booleans pass through")
  end)
end
