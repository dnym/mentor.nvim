-- The Observer's reporting tool. Like every tool it touches nothing outside
-- its own result: it validates and normalizes what the model wants to
-- report and hands it to the observation engine, which applies the
-- freshness rechecks, deduplication, persistence, and notification policy.
-- Findings never take effect through this call directly.

local M = {}

local CATEGORIES = { correctness = true, design = true, learning = true, praise = true }
local CERTAINTY = { high = true, medium = true, low = true }

local function short_text(value, max)
  if type(value) ~= "string" then
    return ""
  end
  local trimmed = vim.trim(value):gsub("\r", "")
  if #trimmed > max then
    trimmed = trimmed:sub(1, max)
  end
  return trimmed
end

---@param ctx table operation context (carries findings_sink on observer runs)
---@param args table { findings = table[] }
---@return table structured result
function M.report_observations(ctx, args)
  local sink = ctx.findings_sink
  if not sink then
    return {
      ok = false,
      error = "no observation run is receiving reports from here",
    }
  end
  local accepted, notes = 0, {}
  for i, f in ipairs(args.findings) do
    if type(f) ~= "table" then
      notes[#notes + 1] = string.format("finding %d ignored: not an object", i)
    else
      local category = short_text(f.category, 20)
      if not CATEGORIES[category] then
        notes[#notes + 1] =
          string.format("finding %d ignored: category must be correctness, design, learning, or praise", i)
      else
        local certainty = short_text(f.certainty, 10)
        if not CERTAINTY[certainty] then
          certainty = "low" -- uncertainty is required; absent means least confidence
        end
        local refs = {}
        if type(f.refs) == "table" then
          for _, r in ipairs(f.refs) do
            if type(r) == "string" then
              refs[#refs + 1] = vim.trim(r)
            end
          end
        end
        sink[#sink + 1] = {
          category = category,
          summary = short_text(f.summary, 400),
          reasoning = short_text(f.reasoning, 2000),
          certainty = certainty,
          refs = refs,
          question = short_text(f.question, 600),
          issue_key = short_text(f.issue_key, 80),
        }
        accepted = accepted + 1
      end
    end
  end
  if accepted == 0 and #args.findings == 0 then
    return {
      ok = true,
      recorded = 0,
      message = "Explicit clean pass: nothing to publish.",
    }
  end
  if accepted == 0 then
    return {
      ok = false,
      error = "no usable findings: each needs a category of correctness, design, learning, or praise "
        .. "and a summary"
        .. (#notes > 0 and ("; " .. table.concat(notes, "; ")) or ""),
    }
  end
  return {
    ok = true,
    recorded = accepted,
    notes = #notes > 0 and notes or nil,
    message = "Recorded for the engine's checks. Concrete claims still need refs; "
      .. "the engine discards anything it cannot validate against current code.",
  }
end

return M
