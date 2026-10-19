local TestKit = require("../TestKit")
local helpers = require("./helpers")
local describe, it, expect, flush = TestKit.describe, TestKit.it, TestKit.expect, TestKit.flush

describe("developer products", function()
	it("grants a purchase once and acknowledges it", function()
		local cashier, mock = helpers.setup()
		local coins = 0
		cashier:Product(1, function()
			coins += 100
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		local decision = mock:BuyProduct(player, 1)
		expect(decision).toBe("Processed")
		expect(coins).toBe(100)
		expect(#mock:PendingReceipts()).toBe(0)
	end)

	it("passes the player and receipt to the handler", function()
		local cashier, mock = helpers.setup()
		local seenPlayer, seenReceipt
		cashier:Product(7, function(player, receipt)
			seenPlayer, seenReceipt = player, receipt
		end)
		cashier:Start()
		local player = mock:AddPlayer(5)
		mock:BuyProduct(player, 7, 49)
		expect(seenPlayer).toBe(player)
		expect(seenReceipt.ProductId).toBe(7)
		expect(seenReceipt.CurrencySpent).toBe(49)
	end)

	it("never grants a redelivered receipt twice", function()
		local cashier, mock = helpers.setup()
		local coins = 0
		cashier:Product(1, function()
			coins += 100
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		local _, receipt = mock:BuyProduct(player, 1)
		expect(mock:Redeliver(receipt)).toBe("Processed")
		expect(mock:Redeliver(receipt)).toBe("Processed")
		expect(coins).toBe(100)
	end)

	it("grants once when Roblox delivers the same receipt twice at the same time", function()
		local profile = helpers.CashierMock.Profile({ Coins = 0 }, 0.05)
		local cashier, mock = helpers.setup({
			ledger = helpers.Cashier.ProfileLedger({
				getProfile = function()
					return profile
				end,
				pollInterval = 0.01,
			}),
		})
		local grants = 0
		cashier:Product(1, function()
			grants += 1
			profile.Data.Coins += 100
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		local first, second
		local _, receipt
		task.spawn(function()
			first, receipt = mock:BuyProduct(player, 1)
		end)
		-- The first delivery is now waiting for the save; deliver again.
		local pending = mock:PendingReceipts()[1]
		second = mock:Redeliver(pending)
		task.wait(0.2)
		expect(second).toBe("NotProcessedYet")
		expect(first).toBe("Processed")
		expect(grants).toBe(1)
		expect(profile.Data.Coins).toBe(100)
		expect(mock:Redeliver(receipt)).toBe("Processed")
		expect(grants).toBe(1)
	end)

	it("retries later when the player is not in the server", function()
		local cashier, mock = helpers.setup()
		local coins = 0
		cashier:Product(1, function()
			coins += 100
		end)
		cashier:Start()
		expect(mock:BuyProduct(999, 1)).toBe("PlayerNotInServer")
		mock:AddPlayer(999)
		expect(mock:RedeliverPending()).toBe(1)
		expect(coins).toBe(100)
	end)

	it("leaves the receipt open when the grant throws, then grants on retry", function()
		local cashier, mock, logs = helpers.setup()
		local broken = true
		local coins = 0
		cashier:Product(1, function()
			if broken then
				error("inventory full")
			end
			coins += 100
		end)
		local failures = {}
		cashier.Failed:Connect(function(_, reason)
			table.insert(failures, reason)
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		expect(mock:BuyProduct(player, 1)).toBe("NotProcessedYet")
		flush()
		expect(coins).toBe(0)
		expect(failures[1]).toContain("inventory full")
		expect(helpers.hasLog(logs, "inventory full")).toBe(true)
		broken = false
		expect(mock:RedeliverPending()).toBe(1)
		expect(coins).toBe(100)
	end)

	it("lets a handler defer by returning false", function()
		local cashier, mock = helpers.setup()
		local ready = false
		local coins = 0
		cashier:Product(1, function()
			if not ready then
				return false
			end
			coins += 100
			return nil
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		expect(mock:BuyProduct(player, 1)).toBe("NotProcessedYet")
		ready = true
		expect(mock:RedeliverPending()).toBe(1)
		expect(coins).toBe(100)
	end)

	it("leaves unknown products to an existing ProcessReceipt", function()
		local cashier, mock = helpers.setup()
		local legacy = 0
		mock.MarketplaceService.ProcessReceipt = function()
			legacy += 1
			return mock.Enum.ProductPurchaseDecision.PurchaseGranted
		end
		cashier:Product(1, function() end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		expect(mock:BuyProduct(player, 2)).toBe("Processed")
		expect(legacy).toBe(1)
		expect(mock:BuyProduct(player, 1)).toBe("Processed")
		expect(legacy).toBe(1)
	end)

	it("routes unknown products to DefaultProduct", function()
		local cashier, mock = helpers.setup()
		local seen = {}
		cashier:Product(1, function() end)
		cashier:DefaultProduct(function(_, receipt)
			table.insert(seen, receipt.ProductId)
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		expect(mock:BuyProduct(player, 55)).toBe("Processed")
		expect(seen[1]).toBe(55)
	end)

	it("picks up products registered after Start", function()
		local cashier, mock = helpers.setup()
		local granted = false
		cashier:Product(1, function() end)
		cashier:Start()
		cashier:Product(2, function()
			granted = true
		end)
		local player = mock:AddPlayer(101)
		expect(mock:BuyProduct(player, 2)).toBe("Processed")
		expect(granted).toBe(true)
	end)

	it("falls back to ProcessReceipt on servers without BindReceiptHandler", function()
		local cashier, mock = helpers.setup({ mockOptions = { bindReceiptHandler = false } })
		local coins = 0
		cashier:Product(1, function()
			coins += 100
		end)
		cashier:Start()
		expect(mock.MarketplaceService.ProcessReceipt ~= nil).toBe(true)
		local player = mock:AddPlayer(101)
		expect(mock:BuyProduct(player, 1)).toBe("Processed")
		expect(mock:BuyProduct(player, 3)).toBe("NotProcessedYet")
		expect(coins).toBe(100)
	end)

	it("fires Granted with the player, receipt and kind", function()
		local cashier, mock = helpers.setup()
		local event
		cashier.Granted:Connect(function(player, receipt, kind)
			event = { player = player, receipt = receipt, kind = kind }
		end)
		cashier:Product(1, function() end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		mock:BuyProduct(player, 1)
		flush()
		expect(event.player).toBe(player)
		expect(event.receipt.ProductId).toBe(1)
		expect(event.kind).toBe("product")
	end)

	it("rejects registering the same product twice", function()
		local cashier = helpers.setup()
		cashier:Product(1, function() end)
		expect(function()
			cashier:Product(1, function() end)
		end).toThrow("already registered")
	end)
end)

return nil
