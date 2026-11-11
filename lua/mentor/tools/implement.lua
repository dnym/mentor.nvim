-- The single Implement-mode tool. Like every tool it cannot touch editor
-- state or disk: it hands replacement text to the implement module, which
-- records a proposal bound to the range captured by the explicit
-- :MentorImplement command. Acceptance is a separate developer action;
-- nothing here applies anything.

local M = {}

---Submit replacement text for the currently captured target range.
---The require is deferred to avoid a load cycle through the tool registry.
---@param ctx table operation context (carries the project)
---@param args table { replacement, explanation? }
---@return table structured result
function M.propose_edit(ctx, args)
  local implement = require("mentor.implement")
  return implement.intake(ctx.project, args)
end

return M
