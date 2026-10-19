-- The scenarios that lose or duplicate purchases in hand-written ProcessReceipt code.
local TestKit = require("../TestKit")
local helpers = require("./helpers")
local describe, it, expect = TestKit.describe, TestKit.it, TestKit.expect
local Cashier, CashierMock = helpers.Cashier, helpers.CashierMock

local function server(mock, profiles)
	local cashier = Cashier.new({
		services = mock.services,
		enums = mock.Enum,
		retryDelay = 0,
		log = function() end,
		ledger = Cashier.ProfileLedger({
			getProfile = function(player)
				return profiles[player.UserId]
			end,
			pollInterval = 0.01,
			saveTimeout = 0.2,
		}),
	})
	cashier:Product(1, function(player)
		profiles[player.UserId].Data.Coins += 100
	end)
	cashier:Start()
	return cashier
end

describe("server crashes (ProfileLedger)", function()
	it("crash before the save: the purchase is granted again on the next server, exactly once", function()
		local mock = CashierMock.new()
		local profiles = {}
		server(mock, profiles)
		local player = mock:AddPlayer(101)
		local profile = CashierMock.Profile({ Coins = 0 })
		profile.failSaves = true -- the server dies before anything is written
		profiles[101] = profile

		expect(mock:BuyProduct(player, 1)).toBe("NotProcessedYet")
		expect(profile.Data.Coins).toBe(100) -- granted in memory only

		-- New server loads what was actually saved: no coins, no record.
		mock:RestartServer()
		local profiles2 = {}
		server(mock, profiles2)
		profiles2[101] = CashierMock.Profile(profile.LastSavedData)
		mock:AddPlayer(101)
		expect(mock:RedeliverPending()).toBe(1)
		expect(profiles2[101].Data.Coins).toBe(100)
		expect(#mock:PendingReceipts()).toBe(0)
	end)

	it("crash after the save but before acknowledging: no double grant", function()
		local mock = CashierMock.new()
		local profiles = {}
		server(mock, profiles)
		local player = mock:AddPlayer(101)
		local profile = CashierMock.Profile({ Coins = 0 })
		profiles[101] = profile

		local _, receipt = mock:BuyProduct(player, 1)
		-- Pretend Roblox never got the acknowledgement and the server died.
		mock:RestartServer()
		local profiles2 = {}
		server(mock, profiles2)
		profiles2[101] = CashierMock.Profile(profile.LastSavedData)
		mock:AddPlayer(101)
		expect(mock:Redeliver(receipt)).toBe("Processed")
		expect(profiles2[101].Data.Coins).toBe(100)
	end)

	it("player leaves before their data loads: retried when they come back", function()
		local mock = CashierMock.new()
		local profiles = {}
		server(mock, profiles)
		local player = mock:AddPlayer(101)
		-- profiles[101] is still nil: data is loading
		expect(mock:BuyProduct(player, 1)).toBe("NotProcessedYet")
		mock:RemovePlayer(player)

		mock:AddPlayer(101)
		profiles[101] = CashierMock.Profile({ Coins = 0 })
		expect(mock:RedeliverPending()).toBe(1)
		expect(profiles[101].Data.Coins).toBe(100)
	end)

	it("session ends mid-save: not acknowledged unless the final save had it", function()
		local mock = CashierMock.new()
		local profiles = {}
		server(mock, profiles)
		local player = mock:AddPlayer(101)
		local profile = CashierMock.Profile({ Coins = 0 }, 1)
		profiles[101] = profile
		task.delay(0.05, function()
			profile:EndSession()
		end)
		expect(mock:BuyProduct(player, 1)).toBe("NotProcessedYet")
	end)

	it("slow saves are waited for, then acknowledged", function()
		local mock = CashierMock.new()
		local profiles = {}
		server(mock, profiles)
		local player = mock:AddPlayer(101)
		local profile = CashierMock.Profile({ Coins = 0 }, 0.05)
		profiles[101] = profile
		expect(mock:BuyProduct(player, 1)).toBe("Processed")
		expect(profile.LastSavedData.Coins).toBe(100)
	end)

	it("keeps only the newest purchase IDs", function()
		local mock = CashierMock.new()
		local profile = CashierMock.Profile({ Coins = 0 })
		local cashier = Cashier.new({
			services = mock.services,
			enums = mock.Enum,
			log = function() end,
			ledger = Cashier.ProfileLedger({
				getProfile = function()
					return profile
				end,
				keep = 3,
				pollInterval = 0.01,
			}),
		})
		cashier:Product(1, function()
			profile.Data.Coins += 1
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		for _ = 1, 5 do
			mock:BuyProduct(player, 1)
		end
		expect(profile.Data.Coins).toBe(5)
		expect(#profile.Data.CashierPurchases).toBe(3)
		expect(profile.Data.CashierPurchases[3]).toBe("purchase-5")
	end)

	it("acknowledges right away for profiles without LastSavedData (ProfileService)", function()
		local mock = CashierMock.new()
		local saves = 0
		local profile = {
			Data = { Coins = 0 },
			Save = function()
				saves += 1
			end,
		}
		local cashier = Cashier.new({
			services = mock.services,
			enums = mock.Enum,
			log = function() end,
			ledger = Cashier.ProfileLedger({
				getProfile = function()
					return profile
				end,
			}),
		})
		cashier:Product(1, function()
			profile.Data.Coins += 100
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		expect(mock:BuyProduct(player, 1)).toBe("Processed")
		expect(saves).toBe(1)
		expect(profile.Data.Coins).toBe(100)
	end)
end)

return nil
