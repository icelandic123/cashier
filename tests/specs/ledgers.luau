local TestKit = require("../TestKit")
local helpers = require("./helpers")
local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Cashier, CashierMock = helpers.Cashier, helpers.CashierMock

local function dataStoreSetup(mock)
	return helpers.setup({
		mock = mock,
		ledger = Cashier.DataStoreLedger({ dataStoreService = mock.DataStoreService, retries = 2, retryDelay = 0 }),
	})
end

describe("DataStoreLedger", function()
	it("records each purchase under its own key", function()
		local mock = CashierMock.new()
		local cashier = dataStoreSetup(mock)
		cashier:Product(1, function() end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		local _, receipt = mock:BuyProduct(player, 1)
		local record = mock._stores.CashierPurchases[receipt.PurchaseId]
		expect(record.userId).toBe(101)
	end)

	it("does not grant again on another server", function()
		local mock = CashierMock.new()
		local coins = 0
		local cashier = dataStoreSetup(mock)
		cashier:Product(1, function()
			coins += 100
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		local _, receipt = mock:BuyProduct(player, 1)

		mock:RestartServer()
		local cashier2 = dataStoreSetup(mock)
		cashier2:Product(1, function()
			coins += 100
		end)
		cashier2:Start()
		mock:AddPlayer(101)
		expect(mock:Redeliver(receipt)).toBe("Processed")
		expect(coins).toBe(100)
	end)

	it("retries later when the DataStore is down, without granting", function()
		local mock = CashierMock.new()
		local coins = 0
		local cashier = dataStoreSetup(mock)
		cashier:Product(1, function()
			coins += 100
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		mock:FailNext("GetAsync", 2)
		expect(mock:BuyProduct(player, 1)).toBe("NotProcessedYet")
		expect(coins).toBe(0)
		expect(mock:RedeliverPending()).toBe(1)
		expect(coins).toBe(100)
	end)

	it("does not grant twice when the record write fails", function()
		local mock = CashierMock.new()
		local coins = 0
		local cashier = dataStoreSetup(mock)
		cashier:Product(1, function()
			coins += 100
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		mock:FailNext("UpdateAsync", 2)
		expect(mock:BuyProduct(player, 1)).toBe("NotProcessedYet")
		expect(coins).toBe(100)
		expect(mock:RedeliverPending()).toBe(1)
		expect(coins).toBe(100)
	end)
end)

describe("custom ledgers", function()
	it("accepts any table with Check, Record and Commit", function()
		local mock = CashierMock.new()
		local calls = {}
		local ledger = {
			Check = function(_, _, key)
				table.insert(calls, "Check " .. key)
				return "new"
			end,
			Record = function(_, _, key)
				table.insert(calls, "Record " .. key)
			end,
			Commit = function(_, _, key)
				table.insert(calls, "Commit " .. key)
				return true
			end,
		}
		local cashier = helpers.setup({ mock = mock, ledger = ledger })
		cashier:Product(1, function() end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		expect(mock:BuyProduct(player, 1)).toBe("Processed")
		expect(table.concat(calls, ",")).toBe("Check purchase-1,Record purchase-1,Commit purchase-1")
	end)

	it("treats a throwing ledger as not processed", function()
		local mock = CashierMock.new()
		local ledger = {
			Check = function()
				error("boom")
			end,
			Record = function() end,
			Commit = function()
				return true
			end,
		}
		local granted = false
		local cashier = helpers.setup({ mock = mock, ledger = ledger })
		cashier:Product(1, function()
			granted = true
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		expect(mock:BuyProduct(player, 1)).toBe("NotProcessedYet")
		expect(granted).toBe(false)
	end)
end)

describe("MemoryLedger", function()
	it("warns when used in a live server", function()
		local mock = CashierMock.new({ studio = false })
		local cashier, _, logs = helpers.setup({ mock = mock })
		cashier:Start()
		expect(helpers.hasLog(logs, "MemoryLedger forgets purchases")).toBe(true)
	end)

	it("stays quiet in Studio", function()
		local cashier, _, logs = helpers.setup()
		cashier:Start()
		expect(helpers.hasLog(logs, "MemoryLedger forgets purchases")).toBe(false)
	end)
end)

return nil
