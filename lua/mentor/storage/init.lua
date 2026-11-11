-- SQLite adapter: LuaJIT FFI against the sqlite3 library available to Neovim,
-- parameterized scoped queries only, explicit transactions, migration runner.
-- Verified against the supported baseline in docs/architecture.md.

local ffi = require("ffi")

pcall(
  ffi.cdef,
  [[
typedef void (*mentor_sqlite_dtor)(void*);
int sqlite3_open_v2(const char*, void**, int, const char*);
int sqlite3_close_v2(void*);
const char* sqlite3_errmsg(void*);
const char* sqlite3_errstr(int);
const char* sqlite3_libversion(void);
int sqlite3_busy_timeout(void*, int);
int sqlite3_exec(void*, const char*, void*, void*, char**);
int sqlite3_prepare_v2(void*, const char*, int, void**, const char**);
int sqlite3_step(void*);
int sqlite3_finalize(void*);
int sqlite3_reset(void*);
int sqlite3_clear_bindings(void*);
int sqlite3_bind_text(void*, int, const char*, int, mentor_sqlite_dtor);
int sqlite3_bind_parameter_count(void*);
int sqlite3_bind_int64(void*, int, long long);
int sqlite3_bind_double(void*, int, double);
int sqlite3_bind_null(void*, int);
const unsigned char* sqlite3_column_text(void*, int);
long long sqlite3_column_int64(void*, int);
double sqlite3_column_double(void*, int);
int sqlite3_column_type(void*, int);
int sqlite3_column_count(void*);
const char* sqlite3_column_name(void*, int);
long long sqlite3_last_insert_rowid(void*);
long long sqlite3_changes64(void*);
]]
)

local lib = assert(ffi.load("sqlite3"))

local SQLITE_TRANSIENT = ffi.cast("mentor_sqlite_dtor", -1)
local SQLITE_ROW = 100
local SQLITE_DONE = 101
-- READWRITE | CREATE | NOMUTEX
local OPEN_FLAGS = 0x00000002 + 0x00000004 + 0x00800000
-- Column type codes (sqlite3.h: INTEGER=1, FLOAT=2, TEXT=3, BLOB=4, NULL=5)
local C_INTEGER, C_FLOAT, C_TEXT = 1, 2, 3

local M = {}

-- Overridable for tests; production default bounds UI impact of lock waits.
M.busy_timeout_ms = 5000

---@type cdata|nil
local db
local tx_depth = 0

local function errmsg()
  if db then
    return ffi.string(lib.sqlite3_errmsg(db))
  end
  return "(no database handle)"
end

local function check(rc, context)
  if rc ~= 0 then
    error(
      string.format(
        "mentor.nvim storage: %s failed: %s (%s)",
        context,
        ffi.string(lib.sqlite3_errstr(rc)),
        errmsg()
      ),
      0
    )
  end
end

---Runs a SQL script without parameters (migrations only).
---@param sql string
function M.exec(sql)
  local db_ = M.db()
  local err = ffi.new("char*[1]")
  local rc = lib.sqlite3_exec(db_, sql, nil, nil, err)
  if rc ~= 0 then
    local msg = err[0] ~= nil and ffi.string(err[0]) or ffi.string(lib.sqlite3_errmsg(db_))
    error("mentor.nvim storage: exec failed: " .. msg, 0)
  end
end

---@param sql string
---@return cdata prepared statement
local function prepare(sql)
  local stmt = ffi.new("void*[1]")
  check(lib.sqlite3_prepare_v2(db, sql, -1, stmt, nil), "prepare")
  if stmt[0] == nil then
    error("mentor.nvim storage: empty statement", 0)
  end
  return stmt[0]
end

---@param stmt cdata
---@param params table|nil positional parameters (string/number/boolean/nil)
local function bind(stmt, params)
  if params == nil then
    return
  end
  local count = lib.sqlite3_bind_parameter_count(stmt)
  for i = 1, count do
    local v = params[i]
    local t = type(v)
    if v == nil then
      check(lib.sqlite3_bind_null(stmt, i), "bind null")
    elseif t == "string" then
      check(lib.sqlite3_bind_text(stmt, i, v, #v, SQLITE_TRANSIENT), "bind text")
    elseif t == "number" then
      if v % 1 == 0 and math.abs(v) < 2 ^ 52 then
        check(lib.sqlite3_bind_int64(stmt, i, math.floor(v)), "bind int")
      else
        check(lib.sqlite3_bind_double(stmt, i, v), "bind double")
      end
    elseif t == "boolean" then
      check(lib.sqlite3_bind_int64(stmt, i, v and 1 or 0), "bind bool")
    else
      error("mentor.nvim storage: unsupported parameter type " .. t .. " at position " .. i, 0)
    end
  end
end

---@param stmt cdata
---@return table row mapping column names to values
local function read_row(stmt)
  local row = {}
  local n = lib.sqlite3_column_count(stmt)
  for i = 0, n - 1 do
    local name = ffi.string(lib.sqlite3_column_name(stmt, i))
    local kind = lib.sqlite3_column_type(stmt, i)
    if kind == C_TEXT then
      row[name] = ffi.string(lib.sqlite3_column_text(stmt, i))
    elseif kind == C_INTEGER then
      row[name] = tonumber(lib.sqlite3_column_int64(stmt, i))
    elseif kind == C_FLOAT then
      row[name] = lib.sqlite3_column_double(stmt, i)
    else
      row[name] = nil -- NULL or BLOB (BLOBs are not used by this schema)
    end
  end
  return row
end

---Runs a query and returns all result rows.
---@param sql string must be a single parameterized statement
---@param params table|nil
---@return table[] rows
function M.query(sql, params)
  M.db()
  local stmt = prepare(sql)
  local ok, rows = pcall(function()
    bind(stmt, params)
    local out = {}
    while true do
      local rc = lib.sqlite3_step(stmt)
      if rc == SQLITE_ROW then
        out[#out + 1] = read_row(stmt)
      elseif rc == SQLITE_DONE then
        break
      else
        check(rc, "step")
      end
    end
    return out
  end)
  lib.sqlite3_finalize(stmt)
  if not ok then
    error(rows, 0)
  end
  return rows
end

---Runs a statement that modifies rows.
---@return integer changes, integer|nil last_insert_rowid
function M.execute(sql, params)
  M.db()
  local stmt = prepare(sql)
  local ok, res = pcall(function()
    bind(stmt, params)
    local rc = lib.sqlite3_step(stmt)
    if rc ~= SQLITE_DONE then
      check(rc, "step")
    end
    return { tonumber(lib.sqlite3_changes64(db)), tonumber(lib.sqlite3_last_insert_rowid(db)) }
  end)
  lib.sqlite3_finalize(stmt)
  if not ok then
    error(res, 0)
  end
  return res[1], res[2]
end

---First value of the first column, or nil.
function M.scalar(sql, params)
  local rows = M.query(sql, params)
  local row = rows[1]
  if not row then
    return nil
  end
  local key = next(row)
  return key and row[key] or nil
end

---Runs fn inside an explicit transaction. Nested calls join the outer one.
---@generic T
---@param fn fun(): T
---@return T
function M.transaction(fn)
  M.db()
  if tx_depth == 0 then
    M.exec("BEGIN IMMEDIATE;")
  end
  tx_depth = tx_depth + 1
  local ok, result = pcall(fn)
  tx_depth = tx_depth - 1
  if ok then
    if tx_depth == 0 then
      M.exec("COMMIT;")
    end
    return result
  end
  if tx_depth == 0 then
    -- Roll back, but never mask the original error.
    pcall(M.exec, "ROLLBACK;")
  end
  error(result, 0)
end

---Loads and applies pending migrations from bundled SQL files.
---Uses an explicit glob over runtime paths: nvim_get_runtime_file showed a
---stale match set for newly added .sql files on the tested Neovim build.
local function migrate()
  local files = {}
  for _, root in ipairs(vim.api.nvim_list_runtime_paths()) do
    for _, file in ipairs(vim.fn.glob(root .. "/lua/mentor/storage/migrations/*.sql", false, true)) do
      files[#files + 1] = file
    end
  end
  table.sort(files)
  local current = tonumber(M.query("PRAGMA user_version;")[1].user_version) or 0
  for _, file in ipairs(files) do
    local version = tonumber(string.match(file, "/(%d+)_[-%w]*%.sql$"))
    if version and version > current then
      local body = assert(vim.fn.readfile(file), "unreadable migration " .. file)
      M.transaction(function()
        M.exec(table.concat(body, "\n"))
        M.exec("PRAGMA user_version = " .. version .. ";")
      end)
    end
  end
end

---Opens (and initializes on first use) the plugin database.
---@param path_override string|nil used by tests only
function M.db(path_override)
  if db then
    return db
  end
  local path = path_override or (require("mentor.config").get().data_dir .. "/mentor.db")
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local handle = ffi.new("void*[1]")
  local rc = lib.sqlite3_open_v2(path, handle, OPEN_FLAGS, nil)
  if rc ~= 0 then
    error("mentor.nvim storage: cannot open " .. path .. ": " .. ffi.string(lib.sqlite3_errstr(rc)), 0)
  end
  db = handle[0]
  check(lib.sqlite3_busy_timeout(db, M.busy_timeout_ms), "busy_timeout")
  M.exec("PRAGMA journal_mode=WAL;")
  M.exec("PRAGMA foreign_keys=ON;")
  migrate()
  return db
end

---Closes the database handle (tests and shutdown).
function M.close()
  if db then
    lib.sqlite3_close_v2(db)
    db = nil
    tx_depth = 0
  end
end

---Reports the loaded sqlite version for health checks.
function M.sqlite_version()
  return ffi.string(lib.sqlite3_libversion())
end

-- Test-only escape hatches: a second raw connection for lock contention and
-- the live handle so busy_timeout can be shortened in checks.
---@private
M._lib = lib
---@private
M._open_flags = OPEN_FLAGS
---@private
function M._handle()
  return db
end

return M
