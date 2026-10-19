local Cashier = require("../../src")
local CashierMock = require("../../src/Mock")

local helpers = {}

-- A Cashier wired to a fresh mock, with fast retries and captured logs.
function helpers.setup(options: { [string]: any }?)
	local opts = options or {}
	local mock = opts.mock or CashierMock.new(opts.mockOptions)
	local logs = {}
	local cashier = Cashier.new({
		services = mock.services,
		enums = mock.Enum,
		ledger = opts.ledger or Cashier.MemoryLedger(),
		retries = opts.retries or 2,
		retryDelay = 0,
		debug = true,
		log = function(level, message)
			table.insert(logs, `{level}: {message}`)
		end,
	})
	return cashier, mock, logs
end

function helpers.hasLog(logs: { string }, fragment: string): boolean
	for _, line in logs do
		if string.find(line, fragment, 1, true) then
			return true
		end
	end
	return false
end

helpers.Cashier = Cashier
helpers.CashierMock = CashierMock
return helpers
