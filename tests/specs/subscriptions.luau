local TestKit = require("../TestKit")
local helpers = require("./helpers")
local describe, it, expect, flush = TestKit.describe, TestKit.it, TestKit.expect, TestKit.flush

describe("subscriptions", function()
	it("activates on join for subscribers", function()
		local cashier, mock = helpers.setup()
		local events = {}
		cashier:Subscription("EXP-1", {
			onActive = function(player)
				table.insert(events, `on {player.UserId}`)
			end,
			onInactive = function(player)
				table.insert(events, `off {player.UserId}`)
			end,
		})
		cashier:Start()
		mock._subscriptions["101:EXP-1"] = true
		local player = mock:AddPlayer(101)
		mock:AddPlayer(102)
		flush()
		expect(table.concat(events, ",")).toBe("on 101")
		expect(cashier:IsSubscribed(player, "EXP-1")).toBe(true)
	end)

	it("follows status changes during the session", function()
		local cashier, mock = helpers.setup()
		local events = {}
		cashier:Subscription("EXP-1", {
			onActive = function()
				table.insert(events, "on")
			end,
			onInactive = function()
				table.insert(events, "off")
			end,
		})
		local changes = {}
		cashier.SubscriptionChanged:Connect(function(_, id, active)
			table.insert(changes, `{id}={active}`)
		end)
		cashier:Start()
		local player = mock:AddPlayer(101)
		flush()
		mock:SetSubscribed(player, "EXP-1", true)
		flush()
		mock:SetSubscribed(player, "EXP-1", true)
		flush()
		mock:SetSubscribed(player, "EXP-1", false)
		flush()
		expect(table.concat(events, ",")).toBe("on,off")
		expect(table.concat(changes, ",")).toBe("EXP-1=true,EXP-1=false")
		expect(cashier:IsSubscribed(player, "EXP-1")).toBe(false)
	end)

	it("ignores subscriptions it doesn't track", function()
		local cashier, mock = helpers.setup()
		local ran = false
		cashier:Subscription("EXP-1", {
			onActive = function()
				ran = true
			end,
		})
		cashier:Start()
		local player = mock:AddPlayer(101)
		flush()
		mock:SetSubscribed(player, "EXP-2", true)
		flush()
		expect(ran).toBe(false)
	end)
end)

return nil
