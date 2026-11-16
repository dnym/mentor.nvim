-- Lifecycle helpers for plugin-owned view buffers.
--
-- `:bdelete` does not wipe a buffer: it unloads it and clears its options,
-- variables and mappings, but the buffer stays valid under its name and keeps
-- its buffer-local autocommands. A view reused from that state comes back as
-- an empty, unbound shell (no buftype, no project binding, no keymaps). These
-- helpers treat an unloaded view as gone: it is wiped, so cleanup handlers
-- run and the next open rebuilds it from storage.

local M = {}

---Whether a remembered view buffer can be reused as-is.
---@param buf integer|nil
---@return boolean
function M.usable(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
end

---Returns the buffer already named `name` when it is still a live view;
---a stale (unloaded) one is wiped so the name can be reused. Returns nil
---when the caller must create a fresh buffer.
---@param name string
---@return integer|nil
function M.find(name)
  local buf = vim.fn.bufnr(name)
  if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  if vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  return nil
end

---Wipe the view when it is unloaded (`:bdelete`, `:bunload`), so its
---BufWipeout cleanup runs. Wiping inside BufUnload is not allowed, so it is
---deferred to the main loop.
---@param buf integer
---@param group string|integer
function M.wipe_on_unload(buf, group)
  vim.api.nvim_create_autocmd("BufUnload", {
    buffer = buf,
    group = group,
    once = true,
    callback = function()
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end)
    end,
  })
end

return M
