NVIM ?= nvim

.PHONY: test live-test fmt lint

test:
	$(NVIM) --headless -u tests/minimal_init.lua -c "luafile tests/run.lua" -c "qa!"

# Network checks against a real endpoint; skipped unless both variables are set.
live-test:
	$(NVIM) --headless -u tests/minimal_init.lua -c "lua require('tests.live.live_check')(); require('tests.live.observer_check')(); require('tests.support.harness').summary(); require('tests.support.fs').cleanup()" -c "qa!"

fmt:
	stylua .

lint:
	stylua --check .
