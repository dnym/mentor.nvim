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

---Escape a filesystem path for use inside a curl config file.
local function quote_path(value)
  return quote_config(value)
end

---Returns nil when usable, or an actionable error.
function M.check()
  if vim.fn.executable(M.executable) ~= 1 then
    return "mentor.nvim: transport requires the curl executable; install it (e.g. pacman -S curl)"
  end
  return nil
end

---@class mentor.TransportRequest
---@field url string
---@field method string|nil defaults to POST when a body is present, else GET
---@field headers string[]|nil raw "Name: value" lines, sent through protected stdin
---@field body string|nil request body
---@field timeout_s number|nil
---@field on_delta fun(chunk: string)|nil incremental response delivery
---@field on_exit fun(err: string|nil, exit_code integer|nil)|nil

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
    spool = vim.fn.tempname()
    vim.fn.writefile({}, spool)
    vim.uv.fs_chmod(spool, tonumber("600", 8))
    vim.fn.writefile(vim.split(req.body, "\n", { plain = true }), spool)
    config_lines[#config_lines + 1] = "data-binary = @" .. quote_path(spool)
  end
  local method = req.method or (req.body ~= nil and "POST" or "GET")
  config_lines[#config_lines + 1] = "request = " .. quote_config(method)

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

  local ok, proc = pcall(vim.system, argv, {
    stdin = table.concat(config_lines, "\n") .. "\n",
    text = true,
    timeout = req.timeout_s and (req.timeout_s * 1000 + 5000) or nil,
    stdout = function(_, data)
      if handle.cancelled or done or not data then
        return
      end
      if req.on_delta then
        req.on_delta(data)
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
    if req.on_exit then
      if handle.cancelled then
        req.on_exit("cancelled", nil)
      elseif out.code == 22 then
        req.on_exit("http_error", out.code) -- --fail-with-body on non-2xx
      elseif out.code == 124 then
        req.on_exit("timeout", out.code)
      elseif out.code ~= 0 then
        req.on_exit("transport_error", out.code)
      else
        req.on_exit(nil, out.code)
      end
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
