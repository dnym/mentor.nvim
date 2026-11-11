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
        max_tokens = 2048, -- completion cap; raise it for reasoning models
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
    chat = {
      -- Conversation history sent with each Coach request is trimmed oldest
      -- first to this estimated token budget.
      history_max_tokens = 8000,
    },
    implement = {
      -- Lines of surrounding context shown in the diff preview.
      context_lines = 30,
      -- Byte cap on the targeted range captured from the buffer.
      max_target_bytes = 32768,
      -- Byte cap on a proposed replacement; larger proposals are refused.
      max_replacement_bytes = 65536,
    },
    memory = {
      -- Entries injected into a model request (global + current project,
      -- provenance-authorized) and returned by memory searches.
      recall_limit = 12,
      -- Byte cap on the memory block appended to the system context.
      recall_max_bytes = 4096,
      -- Candidate entries considered per manual consolidation pass.
      consolidate_max_entries = 60,
      -- Entries rendered in the :MentorMemory view (newest first).
      view_max_entries = 300,
    },
    observer = {
      edit_idle_ms = 2000,
      save_debounce_ms = 1000,
      notify_cooldown_ms = 600000, -- ten minutes per finding
      notify_min_gap_ms = 60000, -- at most one unsolicited notification per project per minute
      category_snooze_ms = 1800000, -- thirty minutes
      -- Learning-category findings notify by default (they are usually the
      -- least urgent; the observation list always shows them).
      notify_learning = false,
      -- Byte caps on the change digest handed to the model at pass start.
      digest_total_bytes = 12288,
      digest_file_bytes = 2048,
      -- Findings rendered in :MentorObservations (newest first).
      list_max_items = 100,
    },
    context = {
      -- Additional exclusion patterns applied to every context source
      -- (buffers, traversal, searches, Git output). Patterns match a path
      -- segment or a path and may use * (within a segment), ** (across
      -- segments) and ?. Built-in credential defaults (.env, private keys,
      -- ...) are always excluded and cannot be re-allowed here.
      exclusions = {},
      max_file_bytes = 262144, -- files larger than this are not read
      max_output_bytes = 16384, -- per-result text cap returned by tools
      max_list_entries = 2000, -- entries returned per traversal call
      max_search_files = 500, -- files visited per content search
      max_scan_bytes = 4194304, -- total bytes read per content search
      max_matches = 200, -- matches returned per search call
      max_elapsed_ms = 5000, -- wall-clock bound per tool call
      git_history_limit = 20, -- commits returned by default from history
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
    check(errors, base .. ".max_tokens", p.max_tokens, is_pos_int, "a positive integer of tokens")
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

  check(errors, "chat.history_max_tokens", cfg.chat.history_max_tokens, is_pos_int, "a positive integer")

  for _, key in ipairs({ "context_lines", "max_target_bytes", "max_replacement_bytes" }) do
    check(errors, "implement." .. key, cfg.implement[key], is_nonneg_int, "a non-negative integer")
  end

  for _, key in ipairs({ "recall_limit", "recall_max_bytes", "consolidate_max_entries", "view_max_entries" }) do
    check(errors, "memory." .. key, cfg.memory[key], is_pos_int, "a positive integer")
  end

  for _, key in ipairs({
    "edit_idle_ms",
    "save_debounce_ms",
    "notify_cooldown_ms",
    "notify_min_gap_ms",
    "category_snooze_ms",
    "digest_total_bytes",
    "digest_file_bytes",
    "list_max_items",
  }) do
    check(
      errors,
      "observer." .. key,
      cfg.observer[key],
      is_nonneg_int,
      "a non-negative integer of milliseconds"
    )
  end
  check(errors, "observer.notify_learning", cfg.observer.notify_learning, is_bool, "a boolean")

  check(errors, "context.exclusions", cfg.context.exclusions, is_str_array, "a list of glob patterns")
  for _, key in ipairs({
    "max_file_bytes",
    "max_output_bytes",
    "max_list_entries",
    "max_search_files",
    "max_scan_bytes",
    "max_matches",
    "max_elapsed_ms",
    "git_history_limit",
  }) do
    check(errors, "context." .. key, cfg.context[key], is_pos_int, "a positive integer")
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
  -- Policy decisions and tracked context depend on configuration; notify the
  -- access policy so operations can detect policy changes.
  pcall(function()
    require("mentor.policy").bump()
  end)
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
