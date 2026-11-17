-- Unit: wall-clock timestamps for persisted values.

local H = require("tests.support.harness")
local clock = require("mentor.clock")

return function()
  H.test("now_ms is epoch milliseconds, not the monotonic loop clock", function()
    local now = clock.now_ms()
    H.ok(math.abs(now - os.time() * 1000) < 2000, "matches os.time()")
    H.ok(now >= clock.EPOCH_FLOOR_MS, "past the legacy floor")
  end)

  H.test("format renders dates and marks legacy monotonic values as unknown", function()
    H.eq(clock.format(clock.now_ms(), "%Y"), os.date("%Y"), "current year")
    H.eq(clock.format(35000000, "%Y-%m-%d"), "date unknown", "a since-boot reading has no date")
    H.eq(clock.format(nil, "%Y-%m-%d"), "date unknown", "missing value")
  end)
end
