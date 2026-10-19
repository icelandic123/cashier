local TestKit = require("../TestKit")
local helpers = require("./helpers")
local describe, it, expect, flush = TestKit.describe, TestKit.it, TestKit.expect, TestKit.flush

describe("lifecycle", function()
	it("refuses a second Start", function()
		local cashier = helpers.setup()
		cashier:Start()
		expect(function()
			cashier:Start()
		end).toThrow("already called")
	end)

	it("Destroy unbinds receipts and stops pass handling", function()
		local cashier, mock = helpers.setup()
		local count = 0
		cashier:Product(1, function()
			count += 1
		end)
		cashier:Pass(50, function()
			count += 1
		end)
		cashier:Start()
		cashier:Destroy()
		mock:SetPassOwned(101, 50)
		local player = mock:AddPlayer(101)
		flush()
		expect(mock:BuyProduct(player, 1)).toBe("NoHandler")
		expect(count).toBe(0)
	end)

	it("Destroy clears a ProcessReceipt it set", function()
		local cashier, mock = helpers.setup({ mockOptions = { bindReceiptHandler = false } })
		cashier:Product(1, function() end)
		cashier:Start()
		cashier:Destroy()
		expect(mock.MarketplaceService.ProcessReceipt).toBeNil()
	end)

	it("exposes a version", function()
		expect(type(helpers.Cashier.VERSION)).toBe("string")
	end)
end)

return nil
