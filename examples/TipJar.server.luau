--[[
	A tip jar built on Robux transfers.

	A player picks an amount, Roblox shows its own transfer prompt, and the
	creator receives the Robux. The experience keeps 10% of every transfer.
	Both sides get a receipt, which Cashier handles once each.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Cashier = require(ServerScriptService.Cashier)

local CREATOR_USER_ID = 1 -- replace with the user who receives tips
local TIP_AMOUNTS = { 10, 25, 100 }

local TipRequested = Instance.new("RemoteEvent")
TipRequested.Name = "TipRequested"
TipRequested.Parent = ReplicatedStorage

local cashier = Cashier.new({
	ledger = Cashier.DataStoreLedger({ name = "Tips" }),
})

cashier:OnTransferSent(function(player, receipt)
	player:SetAttribute("Tipped", (player:GetAttribute("Tipped") or 0) + (receipt.CurrencySpent or 0))
end)

cashier:Start()

TipRequested.OnServerEvent:Connect(function(player, amount)
	if not table.find(TIP_AMOUNTS, amount) then
		return
	end
	local ok, result = cashier:PromptTransfer(player, CREATOR_USER_ID, amount)
	if not ok then
		warn(`Tip prompt failed for {player.Name}: {result}`)
	end
end)
