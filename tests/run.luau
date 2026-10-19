-- Runs the test suite with Lune: `lune run tests/run`
local process = require("@lune/process")

-- Roblox provides `task` as a global; Lune keeps it in a library.
getfenv(0).task = require("@lune/task")

local TestKit = require("./TestKit")

require("./specs/products")
require("./specs/crashes")
require("./specs/ledgers")
require("./specs/passes")
require("./specs/subscriptions")
require("./specs/transfers")
require("./specs/lifecycle")

local failed = TestKit.run()
process.exit(if failed > 0 then 1 else 0)
