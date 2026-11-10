-- Configuration: validation and shipped defaults.
-- Validation never fails silently: every problem produces an actionable error
-- naming the offending setting.

local M = {}

local function is_pos_num(v)
  return type(v) == "number" and v > 0
end

local function is_nonneg_int(v)
  return type(v) == "number" and v >= 0 and v % 1 == 0
end

local function is_pos_int(v)
  return type(v) == "number" and v > 0 and v % 1 == 0
end

local function is_str(v)
  return type(v) == "string"
end

local function is_bool(v)
  return type(v) == "boolean"
end

local function is_str_array(v)
  if type(v) ~= "table" then
    return false
  end
  for _, item in ipairs(v) do
    if type(item) ~= "string" then
      return false
    end
  end
  return true
end

function M.defaults()
  return {
    -- Local XDG data directory: SQLite database and generated views live here,
    -- never inside project repositories.
    data_dir = vim.fn.stdpath("data") .. "/mentor",
    dev = {
      -- Exercise the UI against a scripted local provider (tests and
      -- dogfooding without a configured endpoint). Makes no network requests.
      fake_provider = false,
    },
    projects = {
      -- Explicitly authorized external roots beyond the active project root.
      -- Empty by default.
      external_dirs = {},
      -- Explicit root for non-Git projects. When unset, the working directory
      -- captured at first activation is used.
      fallback_root = nil,
    },
    providers = {
      -- Shared defaults; each mode may independently override endpoint,
      -- model, authentication and capabilities.
      default = {
        endpoint = "", -- e.g. https://api.example.com/v1 (OpenAI-compatible base URL)
        model = "",
        api_key_env = "MENTOR_API_KEY", -- credential read from environment, never stored
        timeout_s = 60,
        capabilities = {
          tools = true, -- native tool calling is required for the MVP workflows
          streaming = true,
        },
      },
      observer = {},
      coach = {},
      implement = {},
    },
    limits = {
      -- One automatic retry per operation against the same budget.
      retries_per_operation = 1,
      interactive = {
        operations_per_instance = 1, -- additional explicit requests queue
        model_requests = 8,
        tool_calls = 16,
        elapsed_s = 120,
        est_tokens = 32000,
        tool_result_bytes = 16384,
        tool_total_bytes = 65536,
      },
      background = {
        investigations_per_instance = 1,
        pending_per_project = 1,
        model_requests = 4,
        tool_calls = 8,
        elapsed_s = 60,
        est_tokens = 16000,
        tool_result_bytes = 16384,
        tool_total_bytes = 65536,
        requests_per_hour_per_project = 30,
        est_tokens_per_day_per_project = 100000,
      },
    },
    observer = {
      edit_idle_ms = 2000,
      save_debounce_ms = 1000,
      notify_cooldown_ms = 600000, -- ten minutes per finding
      notify_min_gap_ms = 60000, -- at most one unsolicited notification per project per minute
      category_snooze_ms = 1800000, -- thirty minutes
    },
  }
end

---Validates one setting against a predicate and records an actionable error.
local function check(errors, path, value, predicate, expectation)
  if not predicate(value) then
    errors[#errors + 1] =
      string.format("mentor.nvim config: %s must be %s, got %s", path, expectation, vim.inspect(value))
  end
end

---@param cfg table merged configuration
---@return string[] actionable validation errors
local function validate(cfg)
  local errors = {}
  check(errors, "data_dir", cfg.data_dir, is_str, "a non-empty string")
  check(errors, "dev.fake_provider", cfg.dev.fake_provider, is_bool, "a boolean")

  check(errors, "projects.external_dirs", cfg.projects.external_dirs, is_str_array, "a list of paths")
  if cfg.projects.fallback_root ~= nil then
    check(errors, "projects.fallback_root", cfg.projects.fallback_root, is_str, "a path string or nil")
  end

  local function check_provider(name, p)
    local base = "providers." .. name
    if p == nil then
      return
    end
    check(errors, base .. ".endpoint", p.endpoint, is_str, "a string (empty for unset)")
    check(errors, base .. ".model", p.model, is_str, "a string (empty for unset)")
    check(errors, base .. ".api_key_env", p.api_key_env, is_str, "an environment variable name")
    check(errors, base .. ".timeout_s", p.timeout_s, is_pos_num, "a positive number of seconds")
    check(errors, base .. ".capabilities.tools", p.capabilities.tools, is_bool, "a boolean")
    check(errors, base .. ".capabilities.streaming", p.capabilities.streaming, is_bool, "a boolean")
    if p.endpoint ~= "" and not p.endpoint:match("^https?://") then
      errors[#errors + 1] = "mentor.nvim config: "
        .. base
        .. ".endpoint must start with http:// or https://, got "
        .. vim.inspect(p.endpoint)
    end
  end
  check_provider("default", cfg.providers.default)
  for _, mode in ipairs({ "observer", "coach", "implement" }) do
    local partial = cfg.providers[mode]
    if partial ~= nil and next(partial) ~= nil then
      -- Validate the effective settings the mode will actually use.
      check_provider(mode, vim.tbl_deep_extend("force", {}, cfg.providers.default, partial))
    end
  end

  check(
    errors,
    "limits.retries_per_operation",
    cfg.limits.retries_per_operation,
    is_nonneg_int,
    "a non-negative integer"
  )
  for _, kind in ipairs({ "interactive", "background" }) do
    local base = "limits." .. kind
    for _, key in ipairs({
      "model_requests",
      "tool_calls",
      "elapsed_s",
      "est_tokens",
      "tool_result_bytes",
      "tool_total_bytes",
    }) do
      check(errors, base .. "." .. key, cfg.limits[kind][key], is_pos_int, "a positive integer")
    end
    if kind == "interactive" then
      check(
        errors,
        base .. ".operations_per_instance",
        cfg.limits.interactive.operations_per_instance,
        is_pos_int,
        "a positive integer"
      )
    else
      for _, key in ipairs({
        "investigations_per_instance",
        "pending_per_project",
        "requests_per_hour_per_project",
        "est_tokens_per_day_per_project",
      }) do
        check(errors, base .. "." .. key, cfg.limits.background[key], is_pos_int, "a positive integer")
      end
    end
  end

  for _, key in ipairs({
    "edit_idle_ms",
    "save_debounce_ms",
    "notify_cooldown_ms",
    "notify_min_gap_ms",
    "category_snooze_ms",
  }) do
    check(
      errors,
      "observer." .. key,
      cfg.observer[key],
      is_nonneg_int,
      "a non-negative integer of milliseconds"
    )
  end
  return errors
end

---@type table|nil
local loaded
---@type string[]|nil
local load_errors

---Merges user options over defaults and validates the result.
---@param opts table|nil user options from setup()
---@return table config, table[] errors (empty when valid)
function M.load(opts)
  if opts ~= nil and type(opts) ~= "table" then
    load_errors = { "mentor.nvim setup: options must be a table" }
    loaded = M.defaults()
    return loaded, load_errors
  end
  local merged = vim.tbl_deep_extend("force", M.defaults(), opts or {})
  -- tbl_deep_extend cannot express nil; keep the default when the user
  -- explicitly passes nil.
  load_errors = validate(merged)
  loaded = merged
  return merged, load_errors
end

---@return table config (defaults when setup() has not run)
function M.get()
  if not loaded then
    loaded = M.defaults()
    load_errors = {}
  end
  return loaded
end

---@return string[] actionable validation errors from the last setup()
function M.errors()
  return load_errors or {}
end

---@return boolean
function M.is_valid()
  M.get()
  return #load_errors == 0
end

---Merged provider settings for a mode; mode settings override shared defaults.
---@param mode "observer"|"coach"|"implement"
function M.provider_for(mode)
  local cfg = M.get()
  return vim.tbl_deep_extend("force", cfg.providers.default, cfg.providers[mode] or {})
end

return M
