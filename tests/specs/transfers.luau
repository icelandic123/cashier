local TestKit = require("../TestKit")
local helpers = require("./helpers")
local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect

describe("Robux transfers", function()
	it("handles sender and receiver receipts once each", function()
		local cashier, mock = helpers.setup()
		local received, sent = {}, {}
		cashier:OnTransferReceived(function(player, receipt)
			table.insert(received, `{player.UserId}:{receipt.CurrencySpent}`)
		end)
		cashier:OnTransferSent(function(player)
			table.insert(sent, player.UserId)
		end)
		cashier:Start()
		local sender = mock:AddPlayer(1)
		mock:AddPlayer(2)
		local ok, id = cashier:PromptTransfer(sender, 2, 100)
		expect(ok).toBe(true)
		local a, b = mock:SettleTransfer(id)
		expect(a).toBe("Processed")
		expect(b).toBe("Processed")
		for _, receipt in
			{
				{
					PurchaseId = `{id}-r`,
					PlayerId = 2,
					TransferRequestId = id,
					ReceiptType = mock.Enum.ReceiptType.RobuxTransferReceiver,
				},
			}
		do
			expect(mock:Redeliver(receipt)).toBe("Processed")
		end
		expect(table.concat(received, ",")).toBe("2:100")
		expect(#sent).toBe(1)
	end)

	it("waits for a receiver who isn't in the server", function()
		local cashier, mock = helpers.setup()
		local received = 0
		cashier:OnTransferReceived(function()
			received += 1
		end)
		cashier:Start()
		local sender = mock:AddPlayer(1)
		local _, id = cashier:PromptTransfer(sender, 2, 50)
		local _, toReceiver = mock:SettleTransfer(id)
		expect(toReceiver).toBe("PlayerNotInServer")
		mock:AddPlayer(2)
		expect(mock:RedeliverPending()).toBe(1)
		expect(received).toBe(1)
	end)

	it("validates the amount and receiver before prompting", function()
		local cashier, mock = helpers.setup()
		cashier:Start()
		local sender = mock:AddPlayer(1)
		local ok, err = cashier:PromptTransfer(sender, 2, 5)
		expect(ok).toBe(false)
		expect(err).toContain("10 to 500")
		ok, err = cashier:PromptTransfer(sender, 2, 501)
		expect(ok).toBe(false)
		ok, err = cashier:PromptTransfer(sender, 2, 10.5)
		expect(ok).toBe(false)
		ok, err = cashier:PromptTransfer(sender, 1, 100)
		expect(ok).toBe(false)
		expect(err).toContain("themselves")
		ok, err = cashier:PromptTransfer(sender, -3, 100)
		expect(ok).toBe(false)
	end)

	it("returns the error when Roblox refuses the prompt", function()
		local cashier, mock = helpers.setup()
		cashier:Start()
		local sender = mock:AddPlayer(1)
		mock:FailNext("PromptRobuxTransferAsync", 1, "sender is not eligible")
		local ok, err = cashier:PromptTransfer(sender, 2, 100)
		expect(ok).toBe(false)
		expect(err).toContain("not eligible")
	end)
end)

return nil
