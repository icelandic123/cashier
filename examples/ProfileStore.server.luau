--[[
	Cashier with ProfileStore: the safest setup.

	Purchase IDs are saved inside each player's profile, in the same write as
	the coins they bought, so a purchase can never be granted twice or lost.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Cashier = require(ServerScriptService.Cashier)
local ProfileStore = require(ServerScriptService.ProfileStore)

local PRODUCTS = {
	Coins100 = 1234567, -- replace with your developer product IDs
	Coins1000 = 1234568,
}
local PASSES = {
	VIP = 7654321, -- replace with your pass ID
}

local PlayerStore = ProfileStore.New("PlayerData", {
	Coins = 0,
	VIP = false,
})
local Profiles: { [Player]: any } = {}

local cashier = Cashier.new({
	ledger = Cashier.ProfileLedger({
		getProfile = function(player)
			return Profiles[player]
		end,
	}),
})

cashier:Product(PRODUCTS.Coins100, function(player)
	Profiles[player].Data.Coins += 100
end)

cashier:Product(PRODUCTS.Coins1000, function(player)
	Profiles[player].Data.Coins += 1000
end)

cashier:Pass(PASSES.VIP, function(player)
	player:SetAttribute("VIP", true)
end)

cashier.Granted:Connect(function(player, receipt)
	print(`{player.Name} bought product {receipt.ProductId}`)
end)

cashier:Start()

local function onPlayerAdded(player: Player)
	local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})
	if profile == nil then
		player:Kick("Your data couldn't load. Please rejoin.")
		return
	end
	profile:AddUserId(player.UserId)
	profile:Reconcile()
	profile.OnSessionEnd:Connect(function()
		Profiles[player] = nil
		player:Kick("Your data was opened on another server. Please rejoin.")
	end)
	if player.Parent == Players then
		-- Receipts that arrived while the profile was loading are retried by
		-- Roblox automatically once this is set.
		Profiles[player] = profile
	else
		profile:EndSession()
	end
end

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	local profile = Profiles[player]
	if profile then
		profile:EndSession()
	end
end)
