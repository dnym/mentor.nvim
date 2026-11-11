# mentor.nvim

Learning-oriented AI assistance for Neovim: autonomous in understanding code,
deliberately restrained in writing it.

**Status: Milestone 6 — automatic Observer with user-controlled feedback.**
Project identity, local SQLite storage, an async transport, an interactive
Coach conversation driven end to end against any OpenAI-compatible provider
(streaming responses, native tool use, per-operation budgets, cancellation,
automatic queuing against single-request endpoints), a shared access policy
(path containment, exclusions, secret sanitization), read-only investigation
tools (files/buffers, Git, diagnostics), and shared memory the assistant
manages under strict user precedence are in place. Implement mode turns an
explicitly selected range in one buffer into a previewed, explicitly accepted
buffer edit (`:MentorImplement`). Memory entries keep revisions and
provenance, are inspectable and editable as generated Markdown
(`:MentorMemory`), support revert, reversible deletion, permanent erasure,
and protection, and are re-authorized against the current access policy
before every request. Coach transcripts persist locally and resume across
restarts. The Observer — bounded background reviews of your recent changes —
is off for every project until you explicitly enable it (`:MentorObserve`),
and its findings are only ever advice: deduplicated, freshness-checked,
rate-limited, and fully under your control (`:MentorObservations`).

Requires Neovim **v0.12.6+** on Arch/Arch-based systems (other Linux systems
best effort).

## Installation

lazy.nvim:

```lua
{
  "dnym/mentor.nvim",
  config = function()
    require("mentor").setup({})
  end,
}
```

Manual / other managers: add `plugin/mentor.lua` to your startup and call
`require("mentor").setup({})`.

## Dependencies

| Dependency | Required | Purpose |
|---|---|---|
| Neovim ≥ v0.12.6 | yes | host (`pacman -S neovim`) |
| `curl` | yes | HTTP transport subprocess (`pacman -S curl`) |
| `sqlite` (shared lib) | yes | local storage via LuaJIT FFI (`pacman -S sqlite`) |
| `git` | optional | project roots, status/diff/history tools |
| LSP servers | optional | definition/reference lookup (tools degrade gracefully without) |

Run `:checkhealth mentor` for an actionable report.

## Configuration

All settings are optional; the defaults are the shipped values.

```lua
require("mentor").setup({
  -- data_dir = vim.fn.stdpath("data") .. "/mentor",
  providers = {
    default = {
      endpoint = "https://api.openai.com/v1", -- OpenAI-compatible base URL
      model = "some-tool-calling-model",
      api_key_env = "MENTOR_API_KEY",         -- read from environment, never stored
      timeout_s = 60,
      max_tokens = 2048,   -- completion cap per request; raise it for reasoning models
      capabilities = { tools = true, streaming = true },
    },
    -- Per-mode overrides; any field may be set per mode:
    -- observer = { endpoint = "http://127.0.0.1:11434/v1", model = "local-model" },
  },
  projects = {
    -- external_dirs = { "~/work/shared-libs" }, -- roots beyond the project authorized for reading
    -- fallback_root = "~/work/scratch",  -- explicit root for non-Git projects
  },
  context = {
    -- Additional exclusion patterns for every context source (buffers,
    -- traversal, searches, Git output). Patterns match a path segment or a
    -- path; * stays within a segment, ** crosses segments. Built-in
    -- credential defaults (.env, private keys, ...) are always excluded.
    exclusions = { "build", "**/generated/**" },
    max_file_bytes = 262144,   -- files above this are not read
    max_output_bytes = 16384,  -- per-result text cap
    max_search_files = 500,    -- files visited per content search
    max_matches = 200,         -- matches returned per search
    max_elapsed_ms = 5000,     -- wall-clock bound per tool call
  },
  chat = {
    history_max_tokens = 8000, -- conversation history trimmed oldest-first
  },
  implement = {
    context_lines = 30,        -- lines of surrounding context in the diff preview
    max_target_bytes = 32768,  -- the selected range may not exceed this
    max_replacement_bytes = 65536, -- larger proposals are refused
  },
  memory = {
    recall_limit = 12,          -- entries injected into a request / searched
    recall_max_bytes = 4096,    -- byte cap on the injected memory block
    consolidate_max_entries = 60, -- candidates considered per memory or scheduled pass
    view_max_entries = 300,     -- entries rendered in :MentorMemory
  },
  observer = {
    edit_idle_ms = 2000,        -- automatic pass starts this long after the last edit
    save_debounce_ms = 1000,    -- saves use this (shorter) debounce
    notify_cooldown_ms = 600000, -- ten minutes before the same finding can interrupt again
    notify_min_gap_ms = 60000,  -- at most one unsolicited notification per project per minute
    category_snooze_ms = 1800000, -- "snooze category" duration (thirty minutes)
    notify_learning = false,    -- learning findings stay list-only unless this is on
    digest_total_bytes = 12288, -- byte cap on the change digest per pass
    digest_file_bytes = 2048,   -- per-file cap inside the digest
    list_max_items = 100,       -- findings rendered in :MentorObservations
  },
  dev = { fake_provider = false }, -- offline placeholder provider for UI work
})
```

Investigation limits, notification cadence, and observation timing have
conservative shipped defaults, validated at `setup()`; invalid values produce
named, actionable errors.

## Commands

| Command | Action |
|---|---|
| `:MentorChat` | Open the Coach conversation for the current project |
| `:MentorChatAsk {question}` | Ask Coach immediately |
| `:MentorChatClear` | Clear the Coach transcript for the current project (memory is untouched) |
| `:MentorStop` | Cancel running operations (Coach, consolidation, Implement runs, observation passes) |
| `:MentorStatus` | Configuration, providers, storage, activity, usage, memory and observation totals |
| `:MentorObserve [enable\|disable\|pause\|resume\|review]` | Turn automatic observation on/off for this project (no argument toggles); `pause`/`resume` are session-only; `review` runs one explicit pass without enabling |
| `:MentorObservations` | Open the observation list (dismiss, restore, rate, snooze, mute, Coach handoff) |
| `:MentorExplain [id]` | Ask Coach to explain an observation (default: newest active) |
| `:MentorImplement {instruction}` | Propose a bounded edit for a visual selection or the insertion point; opens a diff preview |
| `:MentorImplementAccept [id]` | Apply the pending proposal (one `u` reverts it) |
| `:MentorImplementReject [id]` | Reject the pending proposal (the buffer stays untouched) |
| `:MentorMemory` | Open the memory view (generated Markdown) for the current project |
| `:MentorMemory revert <id> [rev]` | Re-apply an entry's older revision (defaults to the previous one) |
| `:MentorMemory delete <id>` | Reversible deletion (a tombstone suppresses automatic recreation) |
| `:MentorMemory erase <id>` | Permanent erasure of the entry and its history (chat is untouched) |
| `:MentorMemory protect <id> on\|off` | Release or re-apply user precedence over an entry |
| `:MentorMemory consolidate` | Run one bounded merge pass over redundant entries |

In the Coach buffer, edit a line starting with `> ` and press `<CR>` to send.
Requests made while one is running queue automatically and run in order;
`:MentorStop` cancels the running request (queued ones keep their place).
No global keymaps are imposed.

## Memory

The assistant records durable knowledge as entries in two scopes: *global*
(general goals, explanation preferences) and *project* (architecture,
decisions, conventions). Every entry keeps its revision history, origin,
evidence references, and an uncertainty marker — the assistant's guesses
about you stay marked as hypotheses unless you said them yourself.

`:MentorMemory` opens a generated Markdown view: edit an entry's summary or
content and save to commit, add a `## [new]` block to create, remove a
block to delete. Saves validate against the revisions the view was rendered
at (another Neovim instance writing first produces an explicit conflict,
never a silent merge), commit everything in one transaction, and regenerate
the view. Your edits mark entries protected: the assistant cannot replace
protected entries — at most it records a separate entry for you to
reconcile. Erasure removes the entry and all its history, keeping only a
content-free audit marker; the Coach transcript is cleared separately with
`:MentorChatClear`.

## Implement mode

Select a characterwise or linewise range (or place the cursor where text
should be inserted) and run `:MentorImplement {instruction}`. The target is
frozen before the model runs: one buffer, one range, that buffer's exact
version. The model investigates with the same read-only tools Coach uses and
can only submit replacement text for exactly that range — it cannot pick a
file, move the target, or request more. Blockwise selections are refused
with an explanation; whole-file, new-file, and multi-file changes are not
offered.

Each proposal opens a native diff preview (current vs proposed, with
surrounding context). Nothing changes until you run
`:MentorImplementAccept`; at that moment the target is revalidated — buffer
identity, version, modifiability, and the current access policy. Any
intervening edit invalidates the proposal, even an edit you later undid, and
so does closing the buffer. Accepting applies exactly one buffer edit in a
distinct undo block: one `u` reverts the whole application. The buffer is
never saved by the plugin and generated code is never executed. Proposals
live only in memory; `:MentorStop` cancels a run and withdraws its pending
proposal.

## Observation

The Observer reviews your recent changes in the background and reports
things worth knowing: a call site the diff broke, a design trade-off,
something in the project it thinks you'd find worth learning. It is
**off for every project until you explicitly enable it** with
`:MentorObserve enable`, and the activation is stored together with the
Observer provider's endpoint: change the endpoint and observation turns
itself off until you re-enable it, so a new provider never starts seeing
your code by accident. Enabling states once, plainly, what will be
transmitted — including unsaved buffer content inside the access policy.

Automatic passes start after an edit settles (idle debounce) or after a
save (shorter debounce), never while you are in Insert mode, and each
project keeps at most one pending pass that coalesces to your newest
state. Every pass sees a change digest — diffs against HEAD plus the
current state of modified buffers — capped in size and already filtered
by the access policy (policy-excluded files are counted, never
transmitted). Passes run on their own, tighter budgets than interactive
work, including per-project hourly request and daily token caps shared
across all your Neovim instances, and interactive requests always
preempt background work. Explicit `:MentorObserve review` runs a pass on
demand without turning anything on.

Findings are advice, never actions — the Observer has no way to touch
your code. Before anything is presented, each pass is revalidated: if
your files, the checkout, or the access policy moved while the model was
thinking, the result is marked stale instead of interrupting you.
Findings deduplicate by issue kind and location; dismissing one makes a
later re-confirmation wait out a ten-minute cooldown instead of nagging.
Notifications follow a deliberately quiet policy (praise never
interrupts, low-confidence design notes stay in the list, at most one
unsolicited notification per project per minute, nothing while you are
typing), and `:MentorObservations` puts the rest under your control:
dismiss/restore, useful/not-useful rating, per-category snooze and mute,
and `<CR>` for a Coach handoff (`:MentorExplain`) when you want the
reasoning walked through.

Observation also schedules memory consolidation: at most once per
project per day, only while observation is enabled and redundant
entries are actually pending — the same bounded pass
`:MentorMemory consolidate` runs by hand, under the same protections.

## Development

```sh
make test   # deterministic headless checks
make lint   # stylua check
make fmt    # format
make live-test  # optional live checks; requires MENTOR_LIVE_ENDPOINT and
                # MENTOR_LIVE_MODEL, skipped otherwise (never in CI)
```

See [docs/architecture.md](docs/architecture.md) for settled technical
decisions and [CONTRIBUTING.md](CONTRIBUTING.md) for conventions.

## Privacy notes

- No network requests are made at plugin load or in tests.
- API credentials are read from the environment at request time and are kept
  out of process arguments, logs, and stored records.
- Request bodies (including unsaved buffer content) travel through protected
  input, never the process argument list.
- The model can only choose among fixed, read-only tools; it never selects
  commands, flags, or shells. Path arguments are validated against resolved
  containment — symlink escapes and traversal above the project root are
  denied.
- The only route from the model to your buffers is the Implement workflow:
  a developer command fixes the target first, the model supplies replacement
  text for exactly that range, and a separate explicit accept revalidates
  and applies it. Coach is never even offered the proposal tool, and no tool
  writes to disk.
- Credential files (`.env`, private keys, …) and configured exclusions are
  hidden from every context source: buffers, listings, searches, Git output,
  and stored context. Detected secrets in tool results are redacted before
  the result is returned, logged, or persisted.
- Investigation tools never write to project files; Git adapters are
  read-only views and are labeled as such (unsaved buffer edits are not
  part of Git results).
- Coach conversations are stored locally (sanitized) and only ever sent
  back to your configured provider; history is trimmed to a bounded token
  budget. Clearing them (`:MentorChatClear`) is a separate action from
  memory erasure, and memory erasure never touches conversation material.
- Memory writes go through a dedicated tool interface confined to memory
  storage: the model cannot write files with it, entries are sanitized for
  detected secrets before storage, and project knowledge stays in project
  scope (global entries must not carry paths or project-identifying
  details). What the assistant infers about you stays marked as a
  hypothesis until you state it or verify it.
- Memory entries carry provenance; entries sourced from a path that later
  becomes excluded are withheld from retrieval and from replayed tool
  results instead of being retransmitted.
- Stored tool results are re-authorized against the current access policy
  before every model request: a file excluded after the fact is withheld
  from later requests even if it was read earlier in the same conversation.
- Observation is opt-in per project and bound to the endpoint it was
  enabled against: changing the provider endpoint disables it until
  re-enabled, and enabling says once what will be transmitted. Its change
  digest is policy-filtered before composition (excluded files are
  counted, never sent) and size-capped; finding refs are re-authorized
  against the current policy before publication, and a finding resting
  on a newly excluded path is withheld entirely.
- Background observation load is capped per project across all running
  instances (hourly requests, daily estimated tokens) in local storage,
  so several editors against one project cannot stack up provider load;
  interactive requests always preempt background passes.
- Every model request first reserves its budget locally (atomic, crash-safe):
  model-request, tool-call, token, and wall-clock limits are enforced before
  dispatch, and an interrupted request stays accounted for rather than
  invisible.
