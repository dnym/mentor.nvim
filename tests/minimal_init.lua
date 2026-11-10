-- Minimal deterministic editor environment for headless checks.
-- Usage: nvim --headless -u tests/minimal_init.lua -c "luafile tests/run.lua" -c "qa!"

local root = vim.uv.cwd()
vim.opt.runtimepath:prepend(root)
vim.opt.shortmess:append("c")
vim.opt.swapfile = false

-- Keep test notifications quiet; specs can inspect the collected messages.
vim.notify = function(msg, level, opts)
  _G._mentor_notifications = _G._mentor_notifications or {}
  table.insert(_G._mentor_notifications, { msg = msg, level = level, opts = opts })
end
