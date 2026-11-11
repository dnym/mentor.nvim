# Architecture decisions

Settled choices from the Milestone 1 spike and the work since. This document
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
  explicit transactions, tracked by `PRAGMA user_version`. Migration files are
  discovered by globbing runtime paths: `nvim_get_runtime_file` returned a
  stale match set for files added after startup on the tested build.
- Conversations (migration 002): one linear Coach transcript per
  (project, mode), stored sanitized; tool messages carry provenance so a
  later policy change can withhold them.
- Usage accounting: a model request first writes an atomic
  `usage_reservation`; it becomes conservatively retained once the request
  actually starts reaching the provider, and folds into daily totals with
  the provider's reported numbers. A reservation that provably never
  dispatched is released; a dispatched one is never undone — a crash leaves
  it charged. Stale reservations are swept once per editor instance.
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
- `vim.system` callbacks run in libuv fast-event contexts, where VimL
  functions and several API calls raise E5560. The transport keeps its own
  callbacks minimal (byte buffering only) and re-delivers stdout chunks and
  process exit through `vim.schedule`, so SSE parsing, agent dispatch, tool
  execution, and UI writes always run on the main loop, in order.
- The request body spool file is created with libuv calls only (never
  `tempname`/`writefile`) for the same reason. In the curl config, the whole
  `data-binary` value including the `@` must be quoted (`"@/path"`):
  `@"path"` makes curl treat the quotes as part of the filename.

## Project identity

Project identity rules:

- Canonical absolute working-tree root, symlinks resolved (`fs_realpath`);
  nearest containing Git root via `git rev-parse --show-toplevel` with fixed
  argv and `--no-optional-locks` (no writes to the repository).
- Each worktree is a separate project; `--git-common-dir` records the shared
  repository. Nested repositories resolve to their own innermost root and are
  excluded from parent-project traversal (enforced by the access policy).
- Non-Git projects: explicit `projects.fallback_root`, otherwise the directory
  captured at resolution time. Provisional: "captured at activation" is
  currently anchored at the buffer's directory rather than the instance cwd;
  revisit with the project-activation model.
- Resolution tolerates paths not yet on disk (unsaved named buffers) by
  walking to the nearest existing ancestor.

## Access policy and investigation tools

The shared path/access policy (`lua/mentor/policy.lua`) gates every context
source: live buffers, traversal, searches, Git output, and stored context.

- Authorization is resolved-path containment, never a raw string-prefix
  check: the candidate is normalized lexically (`.`/`..` collapsed), then
  its nearest existing ancestor is resolved with `fs_realpath` and must sit
  inside the project root or a configured external root. Symlinks therefore
  cannot carry access outside authorized roots; symlink entries themselves
  are hidden from listings and never followed during traversal.
- Exclusions compose on top of containment. Built-in credential defaults
  (`.env`/`.env.*`, private keys, `.git-credentials`, …) are always excluded
  and cannot be re-allowed; `context.exclusions` globs only add. A path
  segment named `.git` is always denied to file tools — Git content is
  reachable only through the constrained Git adapters.
- Nested repositories are denied from the parent project's policy; they are
  separate projects with their own scope.
- Policy generation counter: reloaded configuration bumps it, and tracked
  context recorded under an older generation verifies as stale.

Tool design (`lua/mentor/tools/`):

- The registry (`tools/init.lua`) validates every request against the
  tool's parameter schema — unknown parameters are rejected rather than
  ignored — and never executes model-supplied commands: argv is
  application-built, fixed. Results are structured; failures come back as
  `{ok=false, error}` instead of throwing. `ok` also clears when a tool
  explicitly reports `available=false`, so consumers have one gate.
- Every returned table is sanitized for secrets on the way out
  (`sanitize.sanitize_tree`), with redaction findings attached. Detection
  covers private-key blocks, known credential formats, and a deliberately
  broad assignment style; best effort, not a guarantee.
- Work is bounded synchronously (entry counts, file and scan bytes, match
  counts, per-call wall-clock via `context.max_elapsed_ms`). Async
  dispatch, operation budgets, and cancellation land with the provider
  loop; the synchronous tools are the budget's first enforcement points.
- File/buffer tools prefer loaded buffer content over disk content,
  including unsaved named buffers that do not exist on disk, and label
  sources (`source = "buffer"`, `unsaved = true`). Binary files are
  skipped with an explicit result.
- Git adapters (`status`, `diff`, `history`) run fixed argv with external
  diff/textconv and pagers disabled, filter excluded paths from output,
  and label results as disk/index or history views — never as including
  unsaved edits.
- Language adapters degrade explicitly: without a language server they
  return `available = false` with a reason and a `search_content`
  alternative; diagnostics carry an honest "freshness unknown" marker.
  LSP-returned locations are re-checked against the access policy.

Context tracking (`lua/mentor/context.lua`): every operation carries a
tracker recording the sources it used — buffer `changedtick`, disk
mtime+size fingerprints, the policy generation, and the recorded Git
HEAD. `verify()` rechecks all of them before results are published or an
observation is made; any buffer edit/close, external file change, policy
reload, or checkout change invalidates recorded work.

Decision kept: the no-worker runtime survives Milestone 2. Traversal and
search are pure Lua over `fs_scandir`/`readfile` under hard caps (no rg
dependency), and Git calls are short bounded subprocesses; measured tool
calls stay well inside the wall-clock budget, so no worker process is
introduced yet.

## Provider loop and budgets (Milestone 3)

Provider adapter (`lua/mentor/provider/openai.lua`):

- OpenAI-compatible Chat Completions only; anything else must fail clearly
  with an actionable error rather than degrade silently. Capabilities
  (native tools, streaming) are declared in configuration, never sniffed.
- SSE is parsed by a standalone line accumulator (`provider/sse.lua`) that
  survives arbitrary chunk boundaries (mid-line, mid-event, many events per
  chunk, CRLF, keep-alive comments). Reasoning-model `reasoning_content`
  deltas are counted but never rendered or stored.
- Streamed tool-call fragments are accumulated by index and validated only
  once complete; an incomplete or undecodable call is a hard
  `malformed_response`, never executed. Accumulated bytes are capped per
  request. Provider error bodies become classified errors
  (`request_rejected` for deterministic request faults, which are not
  retried; `http_error`/`timeout`/`transport_error` as transient).
- Requests are serialized per endpoint by `scheduler.lua` (single-flight
  FIFO): providers that serve one concurrent request never see two of ours;
  queued requests start only when their slot comes up and can be cancelled
  while still queued.

Agent loop (`lua/mentor/agent.lua`):

- Every model request is preceded by budget checks (model requests, tool
  calls, estimated tokens, wall-clock deadline) and an atomic usage
  reservation; limits come from configuration. One automatic retry per
  operation for transient failures only.
- Each stored tool result is re-authorized against the current policy
  before every dispatch: newly excluded sources are replaced with a
  withheld marker instead of replaying their content.
- Tool results are capped per result and per operation, with an explicit
  truncation marker the model can see.

Coach UI (`lua/mentor/ui/chat.lua`):

- The buffer is a view of the persisted transcript: on (re)opening, the
  stored conversation renders from storage; streaming appends are dropped
  once the operation is cancelled or its buffer/project binding no longer
  holds. A turn interrupted mid-tool-call is repaired (dangling tool calls
  stripped) when replaying history. Assistant messages are stored
  sanitized; a request in flight plus a FIFO queue keep the interaction
  responsive without refusing follow-ups.

## Chat window scoping

Plugin windows retain their originating project binding
(`b:mentor_project`), and focus autocmds skip plugin buffers, so opening or
entering Coach cannot silently retarget or abandon the source project.
Asynchronous results are only applied while the operation is uncancelled and
its buffer is valid.

## Module status

Landed: `config`, `health`, `commands`, `project`, `policy`, `sanitize`,
`context`, `storage/*`, `provider/{init,fake,transport,sse,openai}`,
`scheduler`, `agent`, `prompts/init`, `tools/{init,files,git,lang}`,
`ui/{chat,status}`, `plugin/mentor.lua`.

Not yet created (deliberate: modules are created when a milestone needs
them): `snapshots`, `budget`, `modes/*`, `memory/*`, `ui/{observations,
diff,memory}`.

Known provisional gaps: the tools run synchronously under internal caps
until async dispatch proves necessary (measured live roundtrips stay well
inside budgets); Coach keeps one linear conversation per project (threaded
conversations and memory arrive with the memory milestone); one-interactive-
operation enforcement is process-global.
