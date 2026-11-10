# Architecture decisions

Settled choices from the Milestone 1 spike and shell work. This document
records how the implementation is shaped and what is still provisional.

## Runtime decision: no separate worker (for now)

The milestone 1 spike exercised the blocking-risk candidates under the
supported baseline (Neovim v0.12.6, LuaJIT, Arch):

- **SQLite access** via LuaJIT FFI against the system `libsqlite3`
  (3.54.1): open, WAL mode, prepared/parameterized statements, and a second
  connection holding a write lock (covered by `tests/integration/storage_spec.lua`).
  Lock waits are bounded by `busy_timeout` (5s default) and surface as errors,
  never hangs.
- **HTTP transport** via an async `curl` subprocess through `vim.system`:
  incremental stdout delivery and cancellation, covered by
  `tests/integration/transport_spec.lua`.
- **Editor responsiveness during slow work**: the Coach chat streams fake
  responses word-by-word while the editor accepts commands
  (`tests/integration/chat_spec.lua`).
- The only synchronous call so far is project-root resolution (`git rev-parse`,
  bounded by a 2s timeout and cached per directory).

Decision: keep the frontend pure Lua; defer the worker. Re-evaluate when
heavier traversal/search and Git work land in Milestone 2. If those cannot
stay off the critical path, introduce a Lua worker before any other language
runtime.

Neovim v0.12 note: `vim.system` handlers are passed as `stdout`/`stderr`
functions inside `opts` and `on_exit` as the third argument — the pre-0.12
`on_stdout` option fields are silently ignored. Transport code and checks are
written against the 0.12 shape.

## Storage

- One SQLite database: `stdpath("data")/mentor/mentor.db` (XDG local data).
  Generated Markdown views and disposable caches will live in the same tree,
  never inside project repositories.
- `journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout=5000`.
- Migrations: ordered `lua/mentor/storage/migrations/NNN_*.sql` applied inside
  explicit transactions, tracked by `PRAGMA user_version`.
- Callers only use scoped, parameterized repository methods
  (`lua/mentor/storage/records.lua`); no arbitrary query construction from
  feature code, and all FFI binding is positional (trailing nils bind NULL).
- Multi-instance use is supported by WAL plus explicit `BEGIN IMMEDIATE`
  transactions; revision checks arrive with the memory milestone.

## Transport

- Fixed executable (`curl`), application-built argv; model input never reaches
  argv or a shell.
- Headers (including the bearer credential) are delivered through the curl
  config on **protected stdin**; request bodies (possibly unsaved buffer
  content) are written to a mode-0600 spool file removed when the request
  settles. Nothing sensitive appears in the process list.
- Incremental delivery via stdout callbacks; cancellation via process signal.
  Error classes are normalized to `cancelled | http_error | timeout |
  transport_error`.
- Provider request construction (OpenAI-compatible Chat Completions, SSE
  decoding, tool-call validation) is Milestone 3 on top of this transport.

## Project identity

Project identity rules:

- Canonical absolute working-tree root, symlinks resolved (`fs_realpath`);
  nearest containing Git root via `git rev-parse --show-toplevel` with fixed
  argv and `--no-optional-locks` (no writes to the repository).
- Each worktree is a separate project; `--git-common-dir` records the shared
  repository. Nested repositories resolve to their own innermost root and are
  flagged for traversal exclusion (enforced by tools in Milestone 2).
- Non-Git projects: explicit `projects.fallback_root`, otherwise the directory
  captured at resolution time. Provisional: "captured at activation" is
  currently anchored at the buffer's directory rather than the instance cwd;
  revisit with the project-activation model in Milestone 2.
- Resolution tolerates paths not yet on disk (unsaved named buffers) by
  walking to the nearest existing ancestor.

## Chat window scoping

Plugin windows retain their originating project binding
(`b:mentor_project`), and focus autocmds skip plugin buffers, so opening or
entering Coach cannot silently retarget or abandon the source project.
Asynchronous results are only applied while the operation is uncancelled and
its buffer is valid.

## Module status

Landed: `config`, `health`, `commands`, `project`, `storage/*`,
`provider/{init,fake,transport}`, `ui/{chat,status}`, `plugin/mentor.lua`.

Not yet created (deliberate: modules are created when a milestone needs
them): `policy`, `sanitize`, `context`, `snapshots`, `scheduler`, `budget`,
`agent`, `tools/*`, `modes/*`, `prompts/*`, `memory/*`, `ui/{observations,diff,memory}`.

Known provisional gaps: Coach conversations are not yet persisted (M3),
one-interactive-operation enforcement is per-chat-buffer (scheduler in M3),
and exclusion/secret policy ships with M2.
