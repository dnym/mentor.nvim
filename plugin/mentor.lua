-- Lightweight command registration at startup: no provider requests, no
-- storage access, and no configuration reads happen here.

if vim.g.loaded_mentor == 1 then
  return
end
vim.g.loaded_mentor = 1

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.schedule(function()
    vim.notify(
      "mentor.nvim requires Neovim v0.12.6 or newer; commands are not registered.",
      vim.log.levels.ERROR
    )
  end)
  return
end

require("mentor.commands").register()
