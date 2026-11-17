-- Pipe-table alignment for the Coach transcript.
--
-- Models emit Markdown tables with ragged columns. This rewrites each table
-- in a block of lines so every column is padded to a common display width,
-- turning the raw text into a readable grid without any renderer plugin.
--
-- Widths are measured as the cell will appear on screen: when `conceal` is
-- requested, the Markdown highlight queries (including any user overrides)
-- are run over the table and their concealed ranges (code span backticks,
-- emphasis markers, link destinations, entities) are applied before the
-- width is taken. Fenced code blocks are left untouched, and the original
-- text is never changed except for whitespace and the delimiter row's dashes.

local M = {}

---Splits a table row into cells on unescaped pipes, with byte offsets.
---@param line string
---@return { text: string, s: integer, e: integer }[]|nil cells (s/e are 0-based, end-exclusive, trimmed)
local function split_row(line)
  if not line:find("|", 1, true) then
    return nil
  end
  local first = line:find("%S")
  if not first then
    return nil
  end
  local last = #line - (#line:match("%s*$"))
  local pos = first
  if line:sub(pos, pos) == "|" then
    pos = pos + 1
  end
  local stop = last
  if stop >= pos and line:sub(stop, stop) == "|" and line:sub(stop - 1, stop - 1) ~= "\\" then
    stop = stop - 1
  end
  local cells = {}
  local start = pos
  local i = pos
  local function push(a, b) -- 1-based inclusive raw span
    local seg = line:sub(a, b)
    local lead = #(seg:match("^%s*"))
    local trimmed = vim.trim(seg)
    cells[#cells + 1] = { text = trimmed, s = a - 1 + lead, e = a - 1 + lead + #trimmed }
  end
  while i <= stop do
    local c = line:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == "|" then
      push(start, i - 1)
      start = i + 1
      i = i + 1
    else
      i = i + 1
    end
  end
  push(start, stop)
  return cells
end

---Parses a delimiter row ("| :--- | ---: |") into per-column alignments.
---@param line string
---@return string[]|nil aligns ("left"|"right"|"center"|"none")
local function parse_delimiter(line)
  local cells = split_row(line)
  if not cells then
    -- A single-column delimiter needs a pipe too in GFM; nothing to do.
    return nil
  end
  local aligns = {}
  for _, cell in ipairs(cells) do
    local l, dashes, r = cell.text:match("^(:?)(%-+)(:?)$")
    if not dashes then
      return nil
    end
    if l == ":" and r == ":" then
      aligns[#aligns + 1] = "center"
    elseif r == ":" then
      aligns[#aligns + 1] = "right"
    elseif l == ":" then
      aligns[#aligns + 1] = "left"
    else
      aligns[#aligns + 1] = "none"
    end
  end
  return aligns
end

---Concealed ranges per row (0-based) of `lines`, from the Markdown highlight
---queries of the parser and every injected language. Empty when the parser
---or queries are unavailable.
---@param lines string[]
---@return table<integer, { s: integer, e: integer, repl: string }[]>
local function conceal_ranges(lines)
  local out = {}
  local ok, parser = pcall(vim.treesitter.get_string_parser, table.concat(lines, "\n"), "markdown")
  if not ok or not parser then
    return out
  end
  if not pcall(parser.parse, parser, true) then
    return out
  end
  parser:for_each_tree(function(tree, ltree)
    local qok, query = pcall(vim.treesitter.query.get, ltree:lang(), "highlights")
    if not qok or not query then
      return
    end
    for id, node, metadata in query:iter_captures(tree:root(), table.concat(lines, "\n")) do
      local repl = metadata.conceal
      if repl == nil and metadata[id] then
        repl = metadata[id].conceal
      end
      if repl == nil and query.captures[id] == "conceal" then
        repl = ""
      end
      if repl ~= nil then
        local range = (metadata[id] and metadata[id].range) or { node:range() }
        local sr, sc, er, ec = range[1], range[2], range[3], range[4]
        if sr == er then
          local row = out[sr] or {}
          row[#row + 1] = { s = sc, e = ec, repl = repl }
          out[sr] = row
        end
      end
    end
  end)
  for _, row in pairs(out) do
    table.sort(row, function(a, b)
      return a.s < b.s or (a.s == b.s and a.e > b.e)
    end)
  end
  return out
end

---On-screen text of `line`'s byte span [s, e) after applying conceals.
local function visible(line, s, e, ranges)
  if not ranges then
    return line:sub(s + 1, e)
  end
  local parts = {}
  local pos = s
  for _, r in ipairs(ranges) do
    if r.s >= pos and r.e <= e and r.s < r.e then
      parts[#parts + 1] = line:sub(pos + 1, r.s)
      parts[#parts + 1] = r.repl
      pos = r.e
    end
  end
  parts[#parts + 1] = line:sub(pos + 1, e)
  return table.concat(parts)
end

---Pads `text` (of display width `w`) to `width` with the given alignment.
local function pad(text, w, width, align)
  local gap = width - w
  if gap <= 0 then
    return text
  end
  if align == "right" then
    return string.rep(" ", gap) .. text
  elseif align == "center" then
    local left = math.floor(gap / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", gap - left)
  end
  return text .. string.rep(" ", gap)
end

---Rebuilds one table (header, delimiter, body rows) with aligned columns.
---@param rows string[] the table's lines; rows[2] is the delimiter
---@param aligns string[]
---@param indent string
---@param conceal boolean
---@return string[]
local function format_table(rows, aligns, indent, conceal)
  local ranges = conceal and conceal_ranges(rows) or {}
  local grid = {}
  local ncols = #aligns
  for r, line in ipairs(rows) do
    if r ~= 2 then
      local cells = split_row(line) or { { text = vim.trim(line), s = 0, e = #line } }
      local row = {}
      for c, cell in ipairs(cells) do
        local shown = visible(line, cell.s, cell.e, conceal and ranges[r - 1] or nil)
        row[c] = { text = cell.text, w = vim.fn.strdisplaywidth(shown) }
      end
      grid[r] = row
      ncols = math.max(ncols, #row)
    end
  end
  local widths = {}
  for c = 1, ncols do
    local align = aligns[c] or "none"
    -- Delimiter cells need at least three dashes plus their colons.
    widths[c] = (align == "center" and 5) or ((align == "left" or align == "right") and 4) or 3
    for r, row in pairs(grid) do
      if r ~= 2 and row[c] then
        widths[c] = math.max(widths[c], row[c].w)
      end
    end
  end
  local out = {}
  for r = 1, #rows do
    local cells = {}
    for c = 1, ncols do
      local align = aligns[c] or "none"
      if r == 2 then
        local w = widths[c]
        if align == "center" then
          cells[c] = ":" .. string.rep("-", w - 2) .. ":"
        elseif align == "right" then
          cells[c] = string.rep("-", w - 1) .. ":"
        elseif align == "left" then
          cells[c] = ":" .. string.rep("-", w - 1)
        else
          cells[c] = string.rep("-", w)
        end
      else
        local cell = grid[r][c] or { text = "", w = 0 }
        cells[c] = pad(cell.text, cell.w, widths[c], align)
      end
    end
    out[r] = indent .. "| " .. table.concat(cells, " | ") .. " |"
  end
  return out
end

---Returns `lines` with every Markdown pipe table outside fenced code blocks
---aligned. Lines that are not part of a table are returned unchanged.
---@param lines string[]
---@param opts? { conceal?: boolean } conceal: measure widths as concealed Markdown displays them
---@return string[] out, boolean changed
function M.align(lines, opts)
  local conceal = opts and opts.conceal or false
  local out = {}
  local changed = false
  local fence -- { char, len } while inside a fenced code block
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local ind, marks = line:match("^( *)(```+)")
    if not marks then
      ind, marks = line:match("^( *)(~~~+)")
    end
    if fence then
      if marks and #ind < 4 and marks:sub(1, 1) == fence.char and #marks >= fence.len then
        local rest = line:sub(#ind + #marks + 1)
        if rest:match("^%s*$") then
          fence = nil
        end
      end
      out[#out + 1] = line
      i = i + 1
    elseif marks and #ind < 4 then
      fence = { char = marks:sub(1, 1), len = #marks }
      out[#out + 1] = line
      i = i + 1
    else
      local indent = line:match("^( *)") or ""
      local header = #indent < 4 and split_row(line)
      local aligns = header and lines[i + 1] and parse_delimiter(lines[i + 1])
      if aligns and #aligns == #header then
        local rows = { line, lines[i + 1] }
        local j = i + 2
        while lines[j] and lines[j]:find("|", 1, true) and not lines[j]:match("^%s*$") do
          rows[#rows + 1] = lines[j]
          j = j + 1
        end
        local formatted = format_table(rows, aligns, indent, conceal)
        for k, f in ipairs(formatted) do
          out[#out + 1] = f
          changed = changed or f ~= rows[k]
        end
        i = j
      else
        out[#out + 1] = line
        i = i + 1
      end
    end
  end
  return out, changed
end

return M
