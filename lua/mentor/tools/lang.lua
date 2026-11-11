-- Editor/language-tool adapters. These degrade explicitly: unavailable
-- tooling and unknown freshness are reported as such and never presented as
-- proof about current code. Results are filtered through the same access
-- policy as everything else.

local project = require("mentor.project")
local files = require("mentor.tools.files")

local M = {}

local SEVERITY = { [1] = "error", [2] = "warning", [3] = "information", [4] = "hint" }

local function project_buffers(ctx)
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.fn.bufloaded(buf) == 1
      and vim.api.nvim_buf_get_name(buf) ~= ""
      and ctx.tracker:same_project(buf)
      and ctx.policy:authorize(vim.api.nvim_buf_get_name(buf))
    then
      out[#out + 1] = buf
    end
  end
  return out
end

---@param ctx table
---@param args table {path?}
function M.get_diagnostics(ctx, args)
  local bufs = {}
  if args.path then
    local access, why = ctx.policy:authorize(args.path)
    if not access then
      return { error = why }
    end
    local buf = files.buffer_for_path(access.abspath)
    if not buf then
      return {
        available = true,
        note = "no loaded buffer for that path; diagnostics live in the editor",
        diagnostics = {},
      }
    end
    bufs = { buf }
  else
    bufs = project_buffers(ctx)
  end

  local items, truncated = {}, false
  for _, buf in ipairs(bufs) do
    ctx.tracker:buffer(buf)
    local canon = project.canonical(vim.api.nvim_buf_get_name(buf)) or ""
    local rel = canon ~= "" and canon:sub(#ctx.project.root + 2) or ""
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      if #items >= ctx.limits.max_matches then
        truncated = true
        break
      end
      items[#items + 1] = {
        path = rel,
        line = d.lnum + 1,
        column = (d.col or 0) + 1,
        severity = SEVERITY[d.severity] or "unknown",
        message = d.message,
        source = d.source,
      }
    end
    if truncated then
      break
    end
  end
  return {
    available = true,
    freshness = "unknown: editor diagnostics carry no timestamp; do not treat them as proof about current code",
    diagnostics = items,
    truncated = truncated,
  }
end

---Shared symbol/references implementation over LSP, honestly degraded when
---language tooling is missing.
---@param ctx table
---@param args table {path, symbol, line?, column?}
---@param method string
local function position_request(ctx, args, method)
  local access, why = ctx.policy:authorize(args.path)
  if not access then
    return { error = why }
  end
  local buf = files.buffer_for_path(access.abspath)
  if not buf then
    return {
      error = "the file is not loaded in a buffer; load it or use search_content for textual lookup",
    }
  end
  ctx.tracker:buffer(buf)

  local ok_clients, clients = pcall(vim.lsp.get_clients, { bufnr = buf })
  if not ok_clients or not clients or #clients == 0 then
    return {
      available = false,
      reason = "no language server is attached to this buffer",
      alternative = "search_content finds textual occurrences; definitions and references need language tooling",
    }
  end

  -- Position: explicit line/column wins; otherwise the first whole-word
  -- occurrence of the symbol in the buffer.
  local line_idx, char_idx = args.line, args.column
  if not line_idx then
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local pattern = "%f[%w_]" .. vim.pesc(args.symbol) .. "%f[%w_]"
    for i, text in ipairs(lines) do
      local c = text:find(pattern)
      if c then
        line_idx, char_idx = i, c
        break
      end
    end
  end
  if not line_idx then
    return {
      available = false,
      reason = "the symbol was not found in the buffer; supply explicit line and column",
    }
  end

  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = line_idx - 1, character = math.max(0, (char_idx or 1) - 1) },
  }
  if method == "textDocument/references" then
    params.context = { includeDeclaration = true }
  end

  local ok, responses = pcall(vim.lsp.buf_request_sync, buf, method, params, 2000)
  if not ok or responses == nil then
    return { available = false, reason = "language server request failed: " .. tostring(responses) }
  end

  local results, skipped, truncated = {}, 0, false
  for _, resp in pairs(responses) do
    local payload = resp.result or resp
    if payload then
      local ok_items, items = pcall(vim.lsp.util.locations_to_items, payload, "utf-16")
      if ok_items then
        for _, item in ipairs(items) do
          if #results >= ctx.limits.max_matches then
            truncated = true
            break
          end
          -- LSP results obey the same policy as file tools.
          local acc = ctx.policy:authorize(item.filename or "")
          if acc then
            results[#results + 1] = { path = acc.rel, line = item.lnum, column = item.col }
          else
            skipped = skipped + 1
          end
        end
      end
    end
    if truncated then
      break
    end
  end
  return { available = true, results = results, skipped_out_of_scope = skipped, truncated = truncated }
end

---@param ctx table
---@param args table {path, symbol, line?, column?}
function M.find_symbol(ctx, args)
  return position_request(ctx, args, "textDocument/definition")
end

---@param ctx table
---@param args table {path, symbol, line?, column?}
function M.find_references(ctx, args)
  return position_request(ctx, args, "textDocument/references")
end

return M
