NVIM ?= nvim

.PHONY: test fmt lint

test:
	$(NVIM) --headless -u tests/minimal_init.lua -c "luafile tests/run.lua" -c "qa!"

fmt:
	stylua .

lint:
	stylua --check .
