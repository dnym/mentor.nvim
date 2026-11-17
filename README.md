# mentor.nvim

Learning-oriented AI assistance for Neovim: autonomous in understanding code,
deliberately restrained in writing it.

Mentor works with any OpenAI-compatible provider, hosted or local (llama.cpp,
Ollama, …), and has three modes:

- **Coach** (`:MentorChat`) — a Socratic chat about your project. It reads
  code with read-only tools (files, buffers, Git, diagnostics, LSP) and
  prefers hints and questions over handing you finished solutions.
- **Implement** (`:MentorImplement`) — the only way Mentor edits code: you
  select a range, the model proposes replacement text for exactly that
  range, you review a diff, and nothing changes until you accept.
- **Observer** (`:MentorObserve`) — optional background review of your recent
  changes. Off until you enable it per project; its findings are advice only.

Mentor also keeps a **memory** of project decisions and your learning goals,
which you can inspect and edit as Markdown (`:MentorMemory`). Conversations,
memory, and findings are stored locally in SQLite.

New to Mentor? [docs/tutorial.md](docs/tutorial.md) walks through all of it
by adding a small module to nginx: Coach for learning the codebase,
Implement for the boilerplate, and the Observer for catching mistakes.

Requires Neovim **v0.12.6+**. Developed on Arch Linux; other Linux systems
are best effort.

## Installation

Built-in `vim.pack`:

```lua
vim.pack.add({ "https://github.com/dnym/mentor.nvim" })
require("mentor").setup({
  providers = { default = { endpoint = "http://127.0.0.1:8080/v1", model = "your-model" } },
})
```

lazy.nvim:

```lua
{
  "dnym/mentor.nvim",
  config = function()
    require("mentor").setup({
      providers = { default = { endpoint = "http://127.0.0.1:8080/v1", model = "your-model" } },
    })
  end,
}
```

Other managers: put the plugin on your runtimepath and call
`require("mentor").setup({...})`.

Nothing talks to a model until an endpoint and model are configured. Run
`:checkhealth mentor` to see what is missing, then `:MentorChat` to start.

## Dependencies

| Dependency | Required | Purpose |
|---|---|---|
| Neovim ≥ v0.12.6 | yes | host |
| `curl` | yes | HTTP transport |
| `sqlite` shared library (Arch: `sqlite`; Debian/Ubuntu: `libsqlite3-0`, usually preinstalled; no `-dev` package needed) | yes | local storage, via LuaJIT FFI |
| `git` | optional | project roots; status, diff, and history tools |
| LSP servers | optional | definition and reference lookup |

## Configuration

Everything except the provider endpoint and model is optional. The values
below are the defaults (the common ones; `lua/mentor/config.lua` lists all); invalid values are reported by name at `setup()`.

```lua
require("mentor").setup({
  -- data_dir = vim.fn.stdpath("data") .. "/mentor",
  providers = {
    default = {
      endpoint = "",                  -- OpenAI-compatible base URL, e.g. "http://127.0.0.1:8080/v1"
      model = "",
      api_key_env = "MENTOR_API_KEY", -- environment variable holding the key; never stored
      timeout_s = 60,
      max_tokens = 2048,              -- completion cap; also caps reasoning tokens, so raise it for reasoning models
      capabilities = { tools = true, streaming = true },
    },
    -- Any field can be overridden per mode:
    -- observer = { endpoint = "http://127.0.0.1:11434/v1", model = "small-local-model" },
    -- coach = {}, implement = {},
  },
  projects = {
    -- external_dirs = { "~/work/shared-libs" }, -- extra roots Mentor may read
    -- fallback_root = "~/work/scratch",          -- root for non-Git projects
  },
  context = {
    -- Extra exclusions for every context source (buffers, listings, searches,
    -- Git output). Patterns match a path or path segment; * stays within a
    -- segment, ** crosses segments. Credential files (.env, private keys, …)
    -- are always excluded.
    exclusions = {},
    max_file_bytes = 262144,   -- larger files can only be read as explicit line ranges
    max_output_bytes = 16384,  -- per-result text cap
    max_search_files = 500,    -- files visited per content search
    max_matches = 200,         -- matches returned per search
    max_elapsed_ms = 5000,     -- time limit per tool call
  },
  limits = {
    interactive = {            -- per Coach / Implement request
      model_requests = 8,
      tool_calls = 16,
      elapsed_s = 120,
      est_tokens = 32000,      -- estimated size cap for each model request; old tool results are trimmed to fit
    },
    background = {             -- per Observer / consolidation pass
      model_requests = 4,
      tool_calls = 8,
      elapsed_s = 60,
      est_tokens = 16000,
      requests_per_hour_per_project = 30,      -- shared across Neovim instances
      est_tokens_per_day_per_project = 100000,
    },
  },
  chat = {
    history_max_tokens = 8000, -- Coach history is trimmed oldest-first to this
    markdown = true,           -- render the transcript as Markdown
    align_tables = true,       -- pad Markdown table columns in replies
  },
  implement = {
    context_lines = 30,            -- context lines in the diff preview
    max_target_bytes = 32768,      -- largest selectable range
    max_replacement_bytes = 65536, -- larger proposals are refused
  },
  memory = {
    recall_limit = 12,            -- entries included in a request
    recall_max_bytes = 4096,      -- size cap on included memory
    consolidate_max_entries = 60, -- entries considered per merge pass
    view_max_entries = 300,       -- entries shown in :MentorMemory
  },
  observer = {
    edit_idle_ms = 2000,          -- review starts this long after your last edit
    save_debounce_ms = 1000,      -- ... or this long after a save
    notify_cooldown_ms = 600000,  -- before a dismissed finding may notify again
    notify_min_gap_ms = 60000,    -- at most one notification per project per minute
    category_snooze_ms = 1800000, -- "snooze category" duration
    notify_learning = false,      -- learning findings stay in the list unless true
    digest_total_bytes = 12288,   -- size cap on the change summary sent per pass
    digest_file_bytes = 2048,     -- per-file cap inside it
    list_max_items = 100,         -- findings shown in :MentorObservations
  },
  dev = { fake_provider = false }, -- offline placeholder provider for UI work
})
```

## Commands

| Command | Action |
|---|---|
| `:MentorChat` | Open the Coach chat for the current project |
| `:MentorChatAsk {question}` | Ask Coach directly |
| `:MentorChatClear` | Clear the project's Coach transcript (memory is untouched) |
| `:MentorStop` | Cancel everything running (chat, Implement, Observer, consolidation) |
| `:MentorStatus` | Configuration, providers, storage, activity, and usage |
| `:MentorImplement {instruction}` | Propose an edit for the visual selection (or insert at the cursor) |
| `:MentorImplementAccept [id]` | Apply the pending proposal (one `u` undoes it) |
| `:MentorImplementReject [id]` | Discard the pending proposal |
| `:MentorObserve [enable\|disable\|pause\|resume\|review]` | Control automatic review for this project; no argument toggles, `pause`/`resume` last for this session, `review` runs one pass without enabling |
| `:MentorObservations` | List findings (dismiss, rate, snooze, mute, explain) |
| `:MentorExplain [id]` | Ask Coach to explain a finding (default: the newest) |
| `:MentorMemory` | Open the editable memory view for the current project |
| `:MentorMemory revert <id> [rev]` | Restore an entry's earlier revision (default: the previous one) |
| `:MentorMemory delete <id>` | Delete an entry, reversibly |
| `:MentorMemory erase <id>` | Permanently erase an entry and its history |
| `:MentorMemory protect <id> on\|off` | Toggle whether the assistant may change an entry |
| `:MentorMemory consolidate` | Merge redundant entries once |

No global keymaps are set.

## Coach

`:MentorChat` opens a per-project chat buffer. Edit a line starting with
`> ` and press `<CR>` on it to send. Requests made while one is running queue up and run in
order, and the transcript persists across restarts. Coach investigates
before answering, grounds its claims in code it has actually read, and
escalates from hints to direct answers when you ask it to.

The transcript renders as Markdown using Neovim's bundled treesitter
parser: headings, bold/italic, inline code, links, lists, tables, and
fenced code blocks (with the code's own language highlighted) are
colored, and emphasis/code markers are concealed (`conceallevel=2`; move
the cursor onto a line to see its raw text). Set `chat.markdown = false`
for a plain buffer. Tables in a reply are aligned once it finishes
streaming: cells are padded to a common width, measured as they appear
with markers concealed (wide-character aware); fenced code is never
touched and the stored transcript keeps the model's original text. Set
`chat.align_tables = false` to show tables as the model wrote them. The
buffer's filetype is `mentorchat`, so a Markdown renderer that attaches
by filetype can take over for richer output (bordered tables, heading
icons), e.g. render-markdown.nvim with
`file_types = { "markdown", "mentorchat" }`.

## Implement

Select a characterwise or linewise range (or place the cursor where text
should go) and run `:MentorImplement {instruction}`. The target is fixed
before the model runs: the model can read the project, but it can only
submit replacement text for that one range. It cannot choose another file
or widen the range.

The proposal opens as a diff. `:MentorImplementAccept` applies it as a
single undo step, but only if the buffer is unchanged since the proposal
was made; any edit in between, even one you undid, invalidates it. Mentor
never saves the buffer and never runs generated code. Blockwise selections
and multi-file changes are not supported.

## Observer

The Observer reviews your recent changes in the background and points out
things worth knowing: a call site your diff broke, a design trade-off,
something worth learning. It is **off for every project** until you run
`:MentorObserve enable`. The activation is tied to the Observer's endpoint,
so changing providers turns it off again until you re-enable it.

A review starts shortly after you stop editing or save, never while you are
in Insert mode. Each pass sends a size-capped summary of your changes
(diffs against HEAD plus unsaved buffers), with excluded files left out.
Background passes have their own smaller budgets and hourly and daily caps,
and they always yield to your interactive requests.

Findings are deduplicated, and a finding whose code changed while the model
was thinking is marked stale instead of notifying you. Notifications are
deliberately rare: at most one per project per minute, none while you type,
and none for praise or low-confidence design notes. `:MentorObservations` holds the
full list, and `<CR>` on a finding hands it to Coach for an explanation.

## Memory

Mentor remembers durable knowledge in two scopes: *global* (your learning
goals and explanation preferences) and *project* (architecture, decisions,
conventions). Guesses the assistant makes about you are marked as hypotheses
until you confirm them.

`:MentorMemory` opens the entries as Markdown. Edit an entry and save to
commit, add a `## [new]` block to create one, or remove a block to delete
it. Entries you edit become protected: the assistant can no longer change
them, only add a separate note for you to reconcile. Every entry keeps its
revision history; deletion is reversible, and erasure removes the entry and
its history for good. While the Observer is enabled, redundant entries are
merged at most once per project per day.

## Privacy and safety

- No network requests at plugin load or in tests; Mentor only contacts the
  endpoints you configure.
- API keys come from the environment at request time. Keys and request
  bodies never appear in process arguments, logs, or storage.
- The model can only call a fixed set of read-only tools. It never runs
  commands, and paths are confined to the project (symlink escapes and `..`
  traversal are denied).
- Credential files (`.env`, private keys, …) and your exclusions are hidden
  from every tool, and detected secrets are redacted before anything is sent
  or stored.
- If you exclude a file after it was read, earlier results from it are
  withheld from later requests instead of being sent again.
- The only path from the model to your code is Implement, and every change
  needs your explicit accept.

## Development

```sh
make test       # headless test suite (no network)
make lint       # stylua check
make fmt        # format
make live-test  # optional checks against a real endpoint; needs
                # MENTOR_LIVE_ENDPOINT and MENTOR_LIVE_MODEL
```

See [docs/architecture.md](docs/architecture.md) for design decisions and
[CONTRIBUTING.md](CONTRIBUTING.md) for conventions.
