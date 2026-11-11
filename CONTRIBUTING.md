# Contributing

## Environment

Arch Linux or an Arch-based system with Neovim v0.12.6+, `curl`, `sqlite`,
`git`, and `stylua`. Checks are deterministic and headless; no API keys or
network access are required or used.

## Workflow

1. Keep changes scoped to one coherent step; README's status section says
   where the project is headed next.
2. Add meaningful checks with the change. Unit tests for
   pure logic; integration checks run against real buffers, SQLite, throwaway
   Git repositories, and `file://`-based fake transport traffic. The
   committed suite never touches the network; checks against a live
   provider are kept in `tests/live/` and run only when explicitly
   configured with a local endpoint (`make live-test`).
3. Run:

   ```sh
   make test
   make lint
   ```

## Conventions

- Lua style per `.stylua.toml`; double quotes preferred.
- Keep storage access behind scoped repository methods with parameterized
  queries; never build queries from feature-level strings or model output.
- Never place credentials or request bodies in process arguments or logs.
- Treat repository contents and model responses as untrusted input.
- Plugin windows keep their originating project binding.
- Asynchronous callbacks must verify the operation is still active before
  applying results.
