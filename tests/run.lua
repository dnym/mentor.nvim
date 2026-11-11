-- Test entry point. Run with: make test
--   nvim --headless -u tests/minimal_init.lua -c "luafile tests/run.lua" -c "qa!"

package.path = (vim.uv.cwd() or ".") .. "/?.lua;" .. package.path

-- Ensure plugin commands exist even if plugin/ autoload is skipped.
require("mentor.commands").register()

io.write("mentor.nvim checks\n")
io.write("=================\n")

require("tests.unit.config_spec")()
require("tests.unit.project_spec")()
require("tests.unit.policy_spec")()
require("tests.unit.sanitize_spec")()
require("tests.unit.sse_spec")()
require("tests.unit.provider_spec")()
require("tests.integration.storage_spec")()
require("tests.integration.conversations_spec")()
require("tests.integration.chat_spec")()
require("tests.integration.agent_spec")()
require("tests.integration.transport_spec")()
require("tests.integration.context_spec")()
require("tests.integration.tools_spec")()
require("tests.integration.memory_spec")()
require("tests.integration.memory_tools_spec")()
require("tests.integration.memory_view_spec")()
require("tests.integration.implement_spec")()
require("tests.integration.observer_spec")()

local H = require("tests.support.harness")
H.summary()
require("tests.support.fs").cleanup()
