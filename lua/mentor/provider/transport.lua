-- Async HTTP transport: a fixed `curl` subprocess with application-built
-- arguments and incremental stdout delivery. Credentials and request bodies
-- never appear in process arguments (they are visible in the process list);
-- headers arrive through stdin config input and the body through a
-- mode-0600 spool file that is removed when the request settles.

local M = {}

M.executable = "curl"

local function quote_config(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---Returns nil when usable, or an actionable error.
function M.check()
  if vim.fn.executable(M.executable) ~= 1 then
    return "mentor.nvim: transport requires the curl executable; install it (e.g. pacman -S curl)"
  end
  return nil
end

local spool_seq = 0

local STATUS_MARKER = "mentor_http_status=" -- no Lua pattern magic characters

---The HTTP status curl reported through write-out, or nil (000 = none).
---@param stderr string|nil
---@return integer|nil
function M._parse_status(stderr)
  local code = tonumber((stderr or ""):match(STATUS_MARKER .. "(%d%d%d)"))
  if code and code > 0 then
    return code
  end
  return nil
end

---Unique spool file path built from libuv only: request() also runs from
---libuv callbacks (chained agent dispatches), where VimL functions such as
---tempname() are off-limits (E5560).
local function spool_path()
  spool_seq = spool_seq + 1
  local ok, tmp = pcall(vim.uv.os_tmpdir)
  local dir = (ok and type(tmp) == "string" and tmp ~= "") and tmp or (os.getenv("TMPDIR") or "/tmp")
  return dir
    .. "/mentor-spool-"
    .. tostring(vim.uv.os_getpid())
    .. "-"
    .. tostring(vim.uv.now())
    .. "-"
    .. tostring(spool_seq)
    .. ".body"
end

---@class mentor.TransportRequest
---@field url string
---@field method string|nil defaults to POST when a body is present, else GET
---@field headers string[]|nil raw "Name: value" lines, sent through protected stdin
---@field body string|nil request body
---@field timeout_s number|nil
---@field on_delta fun(chunk: string)|nil incremental response delivery
---@field on_exit fun(err: string|nil, exit_code integer|nil, http_status integer|nil)|nil

---@param req mentor.TransportRequest
---@return table handle with :cancel(), or nil + actionable error
function M.request(req)
  local err = M.check()
  if err then
    return nil, err
  end

  local spool ---@type string|nil
  local config_lines = { "url = " .. quote_config(req.url) }
  for _, header in ipairs(req.headers or {}) do
    config_lines[#config_lines + 1] = "header = " .. quote_config(header)
  end
  if req.body ~= nil then
    spool = spool_path()
    local fd = vim.uv.fs_open(spool, "w", tonumber("600", 8))
    if not fd then
      return nil, "mentor.nvim: could not create the request spool file"
    end
    vim.uv.fs_write(fd, req.body)
    vim.uv.fs_close(fd)
    -- The whole value (including the leading @) must be quoted: curl reads
    -- @"/path" as a file path containing literal quote characters (exit 26).
    config_lines[#config_lines + 1] = "data-binary = " .. quote_config("@" .. spool)
  end
  local method = req.method or (req.body ~= nil and "POST" or "GET")
  config_lines[#config_lines + 1] = "request = " .. quote_config(method)
  -- The HTTP status goes to stderr (stdout carries the response stream), so
  -- callers can tell transient failures (429/5xx) from deterministic ones.
  -- The write-out format (not the config parser) turns \n into a newline.
  config_lines[#config_lines + 1] = "write-out = "
    .. quote_config("%{stderr}\\n" .. STATUS_MARKER .. "%{http_code}\\n")

  local argv = {
    M.executable,
    "-sS",
    "--fail-with-body",
    "-K",
    "-",
  }
  if req.timeout_s then
    argv[#argv + 1] = "--max-time"
    argv[#argv + 1] = tostring(req.timeout_s)
  end

  local handle = { cancelled = false, active = true, proc = nil }
  local done = false
  local cleanup = function()
    if spool then
      vim.uv.fs_unlink(spool)
    end
  end

  -- vim.system callbacks run in libuv fast-event contexts, where VimL
  -- functions and many API calls (buffer listing, tempname) are forbidden.
  -- Everything downstream — SSE parsing, agent dispatch, tool execution,
  -- UI writes — is delivered through the main loop instead. Scheduled
  -- callbacks keep their FIFO order, so deltas precede on_exit.
  local ok, proc = pcall(vim.system, argv, {
    stdin = table.concat(config_lines, "\n") .. "\n",
    text = true,
    timeout = req.timeout_s and (req.timeout_s * 1000 + 5000) or nil,
    stdout = function(_, data)
      if handle.cancelled or done or not data then
        return
      end
      if req.on_delta then
        local chunk = data
        vim.schedule(function()
          if not handle.cancelled and req.on_delta then
            req.on_delta(chunk)
          end
        end)
      end
    end,
    stderr = function(_, data)
      if data and not handle.cancelled then
        -- Retained only for diagnostics; bodies never contain credentials.
        handle.stderr_tail = ((handle.stderr_tail or "") .. data):sub(-2000)
      end
    end,
  }, function(out)
    if done then
      return
    end
    done = true
    handle.active = false
    cleanup()
    local kind, code
    if handle.cancelled then
      kind, code = "cancelled", nil
    elseif out.code == 22 then
      kind, code = "http_error", out.code -- --fail-with-body on non-2xx
    elseif out.code == 124 then
      kind, code = "timeout", out.code
    elseif out.code ~= 0 then
      kind, code = "transport_error", out.code
    else
      kind, code = nil, out.code
    end
    local status = M._parse_status(handle.stderr_tail)
    if req.on_exit then
      vim.schedule(function()
        req.on_exit(kind, code, status)
      end)
    end
  end)
  if not ok then
    cleanup()
    return nil, "mentor.nvim: could not start transport process: " .. tostring(proc)
  end
  handle.proc = proc

  function handle:cancel()
    if handle.cancelled or done then
      return
    end
    handle.cancelled = true
    -- Attempt to abort transport; already-transmitted data cannot be recalled.
    pcall(function()
      handle.proc:kill(2)
    end)
  end

  function handle:is_active()
    return handle.active
  end
  return handle
end

return M
