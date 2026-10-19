--[[
	Cashier without a session-locked data module.

	DataStoreLedger writes one key per purchase so nothing is granted twice.
	Your own player data is saved separately, so a crash between the two
	writes can still lose a grant; move to ProfileLedger when you can.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Cashier = require(ServerScriptService.Cashier)
local PlayerData = require(ServerScriptService.PlayerData) -- your own module

local cashier = Cashier.new({
	ledger = Cashier.DataStoreLedger({ name = "Purchases" }),
})

cashier:Product(1234567, function(player)
	local data = PlayerData.get(player)
	if not data then
		return false -- not loaded yet: Roblox will retry the receipt
	end
	data.Coins += 100
	PlayerData.save(player)
	return nil
end)

cashier:Start()
