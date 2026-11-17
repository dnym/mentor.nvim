-- Unit: Markdown pipe-table alignment for the Coach view — column padding,
-- alignment colons, conceal-aware and wide-character widths, ragged rows,
-- and fenced code left untouched.

local H = require("tests.support.harness")
local mdtable = require("mentor.ui.mdtable")

return function()
  H.test("pipe tables are padded to common column widths", function()
    local out, changed = mdtable.align({
      "Results:",
      "|Name|Count|",
      "|-|-|",
      "|alpha|1|",
      "|b|12345|",
      "",
      "after",
    })
    H.ok(changed, "reported as changed")
    H.eq(out[1], "Results:", "prose untouched")
    H.eq(out[2], "| Name  | Count |", "header")
    H.eq(out[3], "| ----- | ----- |", "delimiter")
    H.eq(out[4], "| alpha | 1     |", "row 1")
    H.eq(out[5], "| b     | 12345 |", "row 2")
    H.eq(out[7], "after", "text after the table untouched")
    local again, changed_again = mdtable.align(out)
    H.eq(again, out, "idempotent")
    H.ok(not changed_again, "already aligned => unchanged")
  end)

  H.test("alignment colons are kept and honored", function()
    local out = mdtable.align({ "| l | c | r |", "|:--|:-:|--:|", "| x | yy | zzzz |" })
    H.eq(out[2], "| :--- | :---: | ---: |", "delimiter keeps colons")
    H.eq(out[3], "| x    |  yy   | zzzz |", "left, center, right padding")
  end)

  H.test("widths use display width and concealed markup", function()
    local out = mdtable.align({ "| a | b |", "|---|---|", "| 日本 | `x` |" }, { conceal = false })
    H.eq(out[1], "| a    | b   |", "CJK counts two cells per character")
    local shown = mdtable.align({
      "| k | v |",
      "|---|---|",
      "| `x` | **bold** |",
      "| [link](http://example.com/long) | plain |",
    }, { conceal = true })
    H.eq(shown[3], "| `x`    | **bold**  |", "code span measured without backticks")
    H.eq(shown[4], "| [link](http://example.com/long) | plain |", "link measured as its text")
  end)

  H.test("ragged rows, escaped pipes, and indentation", function()
    local out = mdtable.align({ "  | a | b |", "  |---|---|", "  | only |", "  | x \\| y | z | extra |" })
    H.eq(out[1], "  | a      | b   |       |", "header grows to the widest row")
    H.eq(out[2], "  | ------ | --- | ----- |", "delimiter grows too")
    H.eq(out[3], "  | only   |     |       |", "missing cells padded")
    H.eq(out[4], "  | x \\| y | z   | extra |", "escaped pipe stays inside its cell")
  end)

  H.test("fenced code and non-tables are left alone", function()
    local input = {
      "```",
      "|a|b|",
      "|-|-|",
      "```",
      "a | b",
      "not a delimiter",
      "~~~~",
      "|c|d|",
      "|-|-|",
      "~~~",
      "~~~~",
    }
    local out, changed = mdtable.align(input)
    H.eq(out, input, "unchanged")
    H.ok(not changed, "not reported as changed")
  end)
end
