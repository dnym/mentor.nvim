-- Unit: configuration defaults match the shipped values and validation is
-- actionable.

local H = require("tests.support.harness")
local config = require("mentor.config")

return function()
  local function restore()
    config.load({})
  end

  H.test("defaults carry the shipped operation-limit values", function()
    local cfg = config.load({})
    H.eq(cfg.limits.interactive.model_requests, 8, "interactive model requests")
    H.eq(cfg.limits.interactive.tool_calls, 16, "interactive tool calls")
    H.eq(cfg.limits.interactive.elapsed_s, 120, "interactive elapsed")
    H.eq(cfg.limits.interactive.est_tokens, 32000, "interactive tokens")
    H.eq(cfg.limits.background.model_requests, 4, "background model requests")
    H.eq(cfg.limits.background.tool_calls, 8, "background tool calls")
    H.eq(cfg.limits.background.elapsed_s, 60, "background elapsed")
    H.eq(cfg.limits.background.est_tokens, 16000, "background tokens")
    H.eq(cfg.limits.interactive.tool_result_bytes, 16384, "per-result cap")
    H.eq(cfg.limits.background.tool_total_bytes, 65536, "aggregate cap")
    H.eq(cfg.limits.retries_per_operation, 1, "transient retries")
    H.eq(cfg.limits.background.requests_per_hour_per_project, 30, "hourly background requests")
    H.eq(cfg.limits.background.est_tokens_per_day_per_project, 100000, "daily background tokens")
    restore()
  end)

  H.test("defaults carry the observer timing values", function()
    local cfg = config.load({})
    H.eq(cfg.observer.edit_idle_ms, 2000, "edit idle")
    H.eq(cfg.observer.save_debounce_ms, 1000, "save debounce")
    H.eq(cfg.observer.notify_cooldown_ms, 600000, "finding cooldown")
    H.eq(cfg.observer.notify_min_gap_ms, 60000, "notification gap")
    H.eq(cfg.observer.category_snooze_ms, 1800000, "category snooze")
    restore()
  end)

  H.test("partial overrides deep-merge without dropping siblings", function()
    local cfg = config.load({ limits = { interactive = { model_requests = 3 } } })
    H.eq(cfg.limits.interactive.model_requests, 3, "override applied")
    H.eq(cfg.limits.interactive.tool_calls, 16, "sibling preserved")
    H.eq(cfg.limits.background.model_requests, 4, "other section preserved")
    restore()
  end)

  H.test("invalid settings produce actionable named errors", function()
    local _, errors = config.load({
      limits = { interactive = { model_requests = 0 } },
      observer = { edit_idle_ms = -5 },
      providers = { coach = { endpoint = "ftp://nope" } },
    })
    H.ok(#errors >= 3, "expected at least three errors, got " .. vim.inspect(errors))
    local joined = table.concat(errors, "\n")
    H.contains_text(joined, "limits.interactive.model_requests", "names the setting")
    H.contains_text(joined, "observer.edit_idle_ms", "names the setting")
    H.contains_text(joined, "providers.coach.endpoint", "names the setting")
    H.ok(not config.is_valid(), "config marked invalid")
    restore()
    H.ok(config.is_valid(), "valid again after restore")
  end)

  H.test("mode providers override shared defaults", function()
    config.load({
      providers = {
        default = { endpoint = "https://api.example.test/v1", model = "shared-model" },
        coach = { model = "coach-model" },
        observer = { endpoint = "http://127.0.0.1:11434/v1" },
      },
    })
    local coach = config.provider_for("coach")
    H.eq(coach.model, "coach-model", "coach model override")
    H.eq(coach.endpoint, "https://api.example.test/v1", "coach inherits endpoint")
    local obs = config.provider_for("observer")
    H.eq(obs.endpoint, "http://127.0.0.1:11434/v1", "observer endpoint override")
    H.eq(obs.model, "shared-model", "observer inherits model")
    restore()
  end)
end
