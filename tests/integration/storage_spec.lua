-- Integration: SQLite adapter — migrations, scoped repositories, explicit
-- transactions, parameterized access, and a second connection holding a lock.

local H = require("tests.support.harness")
local fs = require("tests.support.fs")
local ffi = require("ffi")
local config = require("mentor.config")
local storage = require("mentor.storage")
local records = require("mentor.storage.records")

return function()
  local function fresh_storage()
    storage.close()
    local data_dir = fs.tmpdir() .. "/data"
    config.load({ data_dir = data_dir })
    return data_dir
  end

  H.test("first open creates the directory, schema, and migration version", function()
    local data_dir = fresh_storage()
    local handle = storage.db()
    H.ok(handle ~= nil, "handle open")
    H.eq(vim.fn.isdirectory(data_dir), 1, "data directory created")
    H.eq(storage.query("PRAGMA user_version;")[1].user_version, 1, "migration applied")
    H.ok(storage.query("SELECT id FROM project;") ~= nil, "project table exists")
  end)

  H.test("migrations are idempotent across reopens", function()
    storage.close()
    storage.db()
    storage.close()
    storage.db()
    H.eq(storage.query("PRAGMA user_version;")[1].user_version, 1, "version stable")
  end)

  H.test("projects.touch is scoped by identity and idempotent", function()
    local a = records.projects.touch({
      identity = "/repo/a",
      root = "/repo/a",
      is_git = true,
      git_common_dir = "/repo/a/.git",
    })
    local b = records.projects.touch({ identity = "/repo/a", root = "/repo/a", is_git = true })
    H.eq(a, b, "same row for the same identity")
    local c = records.projects.touch({ identity = "/repo/b", root = "/repo/b", is_git = false })
    H.neq(a, c, "distinct identities")
    H.eq(records.projects.count(), 2, "scoped count")
    local row = records.projects.get("/repo/b")
    H.eq(row.is_git, 0, "boolean persisted as integer")
    H.eq(row.git_common_dir, nil, "null round-trips to nil")
  end)

  H.test("parameterized access is injection-safe", function()
    local evil = "'; DROP TABLE project; --"
    records.projects.touch({ identity = evil, root = evil, is_git = false })
    H.eq(records.projects.count(), 3, "table still intact")
    H.ok(records.projects.get(evil) ~= nil, "value round-trips verbatim")
  end)

  H.test("transactions commit on success and roll back on error", function()
    local before = records.projects.count()
    records.projects.touch({ identity = "/repo/txn", root = "/repo/txn", is_git = false })
    H.eq(records.projects.count(), before + 1, "committed insert")

    H.expect_error(function()
      storage.transaction(function()
        storage.execute(
          "INSERT INTO project (identity, root, is_git, created_at) VALUES (?, ?, 0, 0);",
          { "/repo/rollback", "/repo/rollback" }
        )
        error("boom", 0)
      end)
    end, "boom", "original error propagates")
    H.eq(records.projects.count(), before + 1, "rolled back insert is gone")
    H.eq(
      storage.scalar("SELECT COUNT(*) FROM project WHERE identity = ?;", { "/repo/rollback" }),
      0,
      "row absent"
    )
  end)

  H.test("a second connection holding a lock surfaces a busy error", function()
    local lib = storage._lib
    local path = config.get().data_dir .. "/mentor.db"
    local h2 = ffi.new("void*[1]")
    local rc = lib.sqlite3_open_v2(path, h2, storage._open_flags, nil)
    H.eq(rc, 0, "second connection opened")
    H.eq(lib.sqlite3_busy_timeout(h2[0], 0), 0, "no wait on the holder")

    -- The holder takes a write lock.
    H.eq(lib.sqlite3_exec(h2[0], "BEGIN IMMEDIATE;", nil, nil, nil), 0, "lock held")

    -- Shorten the plugin handle's busy wait so the check stays fast.
    H.eq(lib.sqlite3_busy_timeout(storage._handle(), 10), 0, "busy timeout set")
    H.expect_error(function()
      storage.execute(
        "INSERT INTO project (identity, root, is_git, created_at) VALUES (?, ?, 0, 0);",
        { "/repo/blocked", "/repo/blocked" }
      )
    end, "locked", "busy surfaces as an error, not a hang")

    lib.sqlite3_exec(h2[0], "COMMIT;", nil, nil, nil)
    lib.sqlite3_close_v2(h2[0])
    -- Write works again once the lock is released.
    storage.execute(
      "INSERT INTO project (identity, root, is_git, created_at) VALUES (?, ?, 0, 0);",
      { "/repo/after-lock", "/repo/after-lock" }
    )
    H.eq(
      storage.scalar("SELECT COUNT(*) FROM project WHERE identity = ?;", { "/repo/after-lock" }),
      1,
      "unblocked write landed"
    )
  end)

  H.test("storage keeps interactive and background work off the lock path with WAL", function()
    local mode = storage.query("PRAGMA journal_mode;")[1].journal_mode
    H.eq(mode, "wal", "WAL journal enabled for concurrent readers")
  end)
end
