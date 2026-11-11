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
  Disposable caches live in the same tree; generated views (memory, status)
  stay editor buffers and are never written into project repositories.
- `journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout=5000`.
- Migrations: ordered `lua/mentor/storage/migrations/NNN_*.sql` applied inside
  explicit transactions, tracked by `PRAGMA user_version`. Migration files are
  discovered by globbing runtime paths: `nvim_get_runtime_file` returned a
  stale match set for files added after startup on the tested build.
- Conversations (migration 002): one linear Coach transcript per
  (project, mode), stored sanitized; tool messages carry provenance and
  their producing tool name so a later policy change can withhold them.
  Transcripts are cleared only through their own explicit path
  (`:MentorChatClear`).
- Memory (migration 003): `memory_entry` (global or project scope, stable
  slug key, category, uncertainty, JSON provenance refs, status with
  tombstones, protected flag, optimistic-concurrency revision),
  `memory_revision` (a full snapshot per revision: the inspectable history
  that powers revert), and `memory_audit` (content-free markers for
  erasure and protection changes). Uniqueness of (scope, project, key) is
  enforced in the repository layer because SQL UNIQUE treats the NULL
  project id of global rows as distinct.
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
  transactions; memory mutations are guarded by expected-revision checks,
  so a stale write from another instance is refused rather than merged.

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

Tool design (`lua/mentor/tools/`): the investigation tools are read-only;
the five `memory_*` tools are the model's only write path, and they are
confined to designated memory storage (they call the memory module, never
the filesystem). Both share one registry and one contract:

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

## Memory and user control (Milestone 4)

Three layers, one authority:

- `storage/records.lua` moves rows (entries, revision snapshots, audit
  markers) through scoped parameterized methods only.
- `memory/init.lua` is the single policy-bearing API: revision guards,
  protection rules, deletion suppression, sanitization on write, and
  provenance rechecks. Everything returns structured
  `{ok, ...}/{ok=false, error}` results; nothing throws at call sites.
- Model-facing tools (`tools/memory.lua`) and user-facing surfaces
  (`ui/memory.lua`, `ui/memory_commands.lua`) both go through that API —
  the model's writes are strictly confined to memory storage (MEM write
  tools cannot touch files), and both paths share the same guards.

Decisions:

- Optimistic concurrency: every mutation carries the revision the writer
  last saw; a stale write (typically another Neovim instance) is refused
  with an actionable message, never merged silently. The memory view's
  save path validates every piece first and commits updates, creations,
  and deletions in one `BEGIN IMMEDIATE` transaction, so a refused piece
  rolls the whole batch back.
- User precedence: any user write marks the entry protected; protected
  entries (and user tombstones) are immune to agent update/delete — the
  tools refuse and tell the model to record a separate entry with its
  evidence instead of overriding the user.
- Deletion is reversible: normal deletes keep a tombstone whose
  (scope, project, key) suppresses automatic agent recreation; revert
  re-applies any history snapshot as a new revision. Permanent erasure
  removes the entry and every revision snapshot, leaving only a
  content-free audit marker. Conversation material is independent and is
  cleared only through its own explicit command.
- Provenance is rechecked, not trusted: entries carry refs (paths and
  bare concepts). A ref counts as path-like only if it looks like a path;
  path-like refs must still be authorized by the current policy, and one
  newly excluded path ref conservatively omits the whole entry (mixed
  sources cannot be separated safely). The same recheck runs over
  serialized `memory_*` tool results embedded in stored history before
  every dispatch and before replaying a persisted transcript — rewriting
  them in place, idempotently via a `withheld` marker.
- Sanitization on write: detected secrets are redacted before entries are
  stored (recorded as redaction findings, not as a rejection) — the
  stored entry stays useful minus the credential.
- The memory view (`mentor://memory/...`, `buftype=acwrite`) is a
  generated Markdown rendering, never a file on disk: SQLite stays the
  only authoritative store, so interrupted generation always recovers by
  reopening. Saving diffs the buffer against the render-time snapshot,
  and a conflict keeps the user's proposed text in the buffer untouched.
- Consolidation is a bounded agent pass (background budgets, only the
  five memory tools) over deterministically grouped candidates
  (same category plus ref/token overlap); protected entries and
  tombstones are excluded from candidates and refused by the tools
  regardless. It is manual (`:MentorMemory consolidate`) by design:
  automatic scheduling waits for the observation-activation machinery.

## Implement mode: proposals with guarded edits (Milestone 5)

One command, one frozen target, one tool, one explicit acceptance
(`lua/mentor/implement/init.lua`):

- The developer command (`:MentorImplement`, `range=true`) captures the
  target before the model runs: buffer, exact 0-based end-exclusive range,
  `changedtick`, path, policy verdict. Characterwise visual marks are
  converted once, multibyte-aware (`'>` sits on the start of the last
  selected character, so the exclusive end extends past its UTF-8 width);
  linewise ranges include the materialized EOL mid-buffer but an
  end-of-buffer range ends at the last line's text (no phantom line);
  a bare command addresses an insertion point at the (clamped) cursor;
  blockwise is refused with an explanation. Whole-file, new-file, and
  multi-file edits are deliberately out of scope.
- Per-mode tool groups (`tools/init.lua`: `investigation`, `memory`,
  `implement`) drive explicit allow-lists at each call site. Coach passes
  `investigation + memory` only, so `propose_edit` is invisible to it —
  the separation is structural, not prompt-level. Implement runs get all
  three groups.
- `propose_edit` takes no path or range parameters (unknown parameters are
  rejected like any tool), so the model cannot smuggle a new target; it
  hands replacement text to `implement.intake`, which validates caps,
  refuses no-op replacements, supersedes the previous pending proposal,
  and renders a native side-by-side diff preview from generated scratch
  buffers sharing identical context lines and omission markers.
- Acceptance revalidates everything against the frozen snapshot: buffer
  validity and load state, name, `changedtick` (any intervening edit
  invalidates — even edit-and-undo, because the version, not the text,
  decides), modifiability, and the current access policy. It then applies
  exactly one `nvim_buf_set_text` preceded by an `undolevels` re-set,
  which closes the current undo block (0.12 removed `undotime`), so a
  single `u` reverts exactly the application. Nothing is written to disk;
  previews and proposals are in-memory only and die with the session.
- `:MentorStop` cancels Implement runs and withdraws their pending
  proposals; status reports active runs and pending proposal counts.

Neovim 0.12 API notes learned here: `nvim_buf_get_text` requires the
explicit 6th opts argument; API text calls reject `end_row == line_count`,
which is why end-of-buffer linewise ranges end at the last line's text;
`'undotime'` no longer exists — re-setting `'undolevels'` (even to the same
value) closes the current undo block.

## Chat window scoping

Plugin windows retain their originating project binding
(`b:mentor_project`), and focus autocmds skip plugin buffers, so opening or
entering Coach cannot silently retarget or abandon the source project.
Asynchronous results are only applied while the operation is uncancelled and
its buffer is valid.

## Module status

Landed: `config`, `health`, `commands`, `project`, `policy`, `sanitize`,
`context`, `storage/*`, `provider/{init,fake,transport,sse,openai}`,
`scheduler`, `agent`, `prompts/init`, `tools/{init,files,git,lang,memory,
implement}`, `implement/init`, `memory/{init,consolidate}`,
`ui/{chat,status,memory,memory_commands}`, `plugin/mentor.lua`.

Not yet created (deliberate: modules are created when a milestone needs
them): `snapshots`, `budget`, `modes/*`, `observer/*`, `ui/observations`.

Known provisional gaps: the tools run synchronously under internal caps
until async dispatch proves necessary (measured live roundtrips stay well
inside budgets); Coach keeps one linear conversation per project
(threaded conversations remain open); memory relevance is rule-based
(scope, refs, recency) until semantic indexing lands; consolidation is
manual until observation activation provides its scheduling gate;
one-interactive-operation enforcement is process-global.
