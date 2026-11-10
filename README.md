# mentor.nvim

Learning-oriented AI assistance for Neovim: autonomous in understanding code,
deliberately restrained in writing it.

**Status: Milestone 1 — plugin shell.** Project identity, local SQLite
storage, async transport plumbing, and an interactive Coach scratch buffer
driven by an offline fake provider are in place. Automatic observation,
persistent memory, operation budgets, and the real provider loop arrive in
later milestones.

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
| `git` | optional | project roots, later history/diff tools |
| LSP servers | optional | later language tools |

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
    -- fallback_root = "~/work/scratch",  -- explicit root for non-Git projects
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
