--[[
	Testing purchase code with Cashier.Mock, no Robux needed.

	Run this in Studio's command bar or from any test runner (TestEZ, Jest
	Lua). The mock stands in for MarketplaceService and Players, so you can
	replay the situations that are hard to cause on purpose.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Cashier = require(ServerScriptService.Cashier)
local CashierMock = require(ServerScriptService.Cashier.Mock)

local mock = CashierMock.new()
local profile = CashierMock.Profile({ Coins = 0 })

local cashier = Cashier.new({
	services = mock.services,
	enums = mock.Enum,
	ledger = Cashier.ProfileLedger({
		getProfile = function()
			return profile
		end,
		saveTimeout = 1, -- keep the "server dies" case below quick
	}),
})
cashier:Product(1, function()
	profile.Data.Coins += 100
end)
cashier:Start()

local player = mock:AddPlayer(101)

-- A normal purchase.
assert(mock:BuyProduct(player, 1) == "Processed", "purchase should be processed")

-- Roblox delivers the same receipt again: nothing is granted twice.
local _, receipt = mock:BuyProduct(player, 1)
assert(mock:Redeliver(receipt) == "Processed", "redelivery should be acknowledged")
assert(profile.Data.Coins == 200, "redelivery must not grant twice")

-- The server dies before saving: the next server grants it, once.
profile.failSaves = true
assert(mock:BuyProduct(player, 1) == "NotProcessedYet", "unsaved purchase must not be acknowledged")
mock:RestartServer()
local nextProfile = CashierMock.Profile(profile.LastSavedData)
local nextServer = Cashier.new({
	services = mock.services,
	enums = mock.Enum,
	ledger = Cashier.ProfileLedger({
		getProfile = function()
			return nextProfile
		end,
	}),
})
nextServer:Product(1, function()
	nextProfile.Data.Coins += 100
end)
nextServer:Start()
mock:AddPlayer(101)
assert(mock:RedeliverPending() == 1, "next server should process the pending receipt")
assert(nextProfile.Data.Coins == 300, "next server should grant exactly once")

print("Cashier purchase tests passed")
