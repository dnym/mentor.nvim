# mentor.nvim

Learning-oriented AI assistance for Neovim: autonomous in understanding code,
deliberately restrained in writing it.

**Status: Milestone 2 — safe context and investigation tools.** Project
identity, local SQLite storage, async transport plumbing, an interactive
Coach scratch buffer driven by an offline fake provider, a shared access
policy (path containment, exclusions, secret sanitization), and a read-only
investigation tool set (files/buffers, Git, diagnostics) are in place.
Automatic observation, persistent memory, operation budgets, and the real
provider loop arrive in later milestones.

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
| `:MentorStop` | Cancel running operations |
| `:MentorStatus` | Configuration, providers, storage, activity |

In the Coach buffer, edit a line starting with `> ` and press `<CR>` to send.
No global keymaps are imposed.

## Development

```sh
make test   # deterministic headless checks
make lint   # stylua check
make fmt    # format
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
- Credential files (`.env`, private keys, …) and configured exclusions are
  hidden from every context source: buffers, listings, searches, Git output,
  and stored context. Detected secrets in tool results are redacted before
  the result is returned, logged, or persisted.
- Investigation tools never write to project files; Git adapters are
  read-only views and are labeled as such (unsaved buffer edits are not
  part of Git results).
