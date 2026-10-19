--!strict
--[=[
	@class CashierMock

	A fake Roblox marketplace for testing purchase code without spending
	Robux, in Studio or in a plain Luau runtime such as Lune. It ships as
	`Cashier.Mock`.

	It plays the parts of `MarketplaceService`, `Players`, `DataStoreService`
	and `RunService`, and lets a test do the things that are hard to make
	happen on purpose: a receipt delivered twice at once, a player leaving
	mid-purchase, a DataStore outage, or a server crashing before a save.

	```lua
	local Cashier = require(path.to.Cashier)
	local CashierMock = require(path.to.Cashier.Mock)

	local mock = CashierMock.new()
	local cashier = Cashier.new({
		services = mock.services,
		enums = mock.Enum,
		ledger = Cashier.MemoryLedger(),
	})
	cashier:Product(1, function(player) coins[player] += 100 end)
	cashier:Start()

	local player = mock:AddPlayer(101)
	local decision = mock:BuyProduct(player, 1)
	assert(decision == "Processed")
	```

	CashierMock is self-contained and does not require Cashier.
]=]

local CashierMock = {}
CashierMock.__index = CashierMock

--------------------------------------------------------------------------------
-- Signal
--------------------------------------------------------------------------------

local MockSignal = {}
MockSignal.__index = MockSignal

function MockSignal.new()
	return setmetatable({ _handlers = {} }, MockSignal)
end

function MockSignal.Connect(self: any, fn)
	local handler = { fn = fn, connected = true }
	table.insert(self._handlers, handler)
	local signal = self
	return {
		Connected = true,
		Disconnect = function(connection)
			connection.Connected = false
			handler.connected = false
			local index = table.find(signal._handlers, handler)
			if index then
				table.remove(signal._handlers, index)
			end
		end,
	}
end

-- Fires handlers synchronously, each in its own thread, so a test sees
-- their effects as soon as they stop yielding.
function MockSignal.Fire(self: any, ...)
	for _, handler in table.clone(self._handlers) do
		if handler.connected then
			task.spawn(handler.fn, ...)
		end
	end
end

--------------------------------------------------------------------------------
-- Enums
--------------------------------------------------------------------------------

local function enumItem(enumName: string, name: string)
	return setmetatable({ Name = name, EnumType = enumName }, {
		__tostring = function()
			return `Enum.{enumName}.{name}`
		end,
	})
end

local Enum = {
	ReceiptDecision = {
		Processed = enumItem("ReceiptDecision", "Processed"),
		NotProcessedYet = enumItem("ReceiptDecision", "NotProcessedYet"),
	},
	ProductPurchaseDecision = {
		PurchaseGranted = enumItem("ProductPurchaseDecision", "PurchaseGranted"),
		NotProcessedYet = enumItem("ProductPurchaseDecision", "NotProcessedYet"),
	},
	ReceiptType = {
		DeveloperProduct = enumItem("ReceiptType", "DeveloperProduct"),
		RobuxTransferSender = enumItem("ReceiptType", "RobuxTransferSender"),
		RobuxTransferReceiver = enumItem("ReceiptType", "RobuxTransferReceiver"),
	},
	CurrencyType = {
		Robux = enumItem("CurrencyType", "Robux"),
	},
}
CashierMock.Enum = Enum

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[deepCopy(k)] = deepCopy(v)
	end
	return copy
end
CashierMock.deepCopy = deepCopy

export type MockPlayer = {
	UserId: number,
	Name: string,
	Character: any,
	CharacterAdded: any,
	Parent: any,
	[string]: any,
}

export type PendingReceipt = {
	receipt: { [string]: any },
	receiptType: any,
	attempts: number,
}

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

--[=[
	Creates a fresh fake marketplace. `options.studio` controls what
	`RunService:IsStudio()` returns (default true).
]=]
function CashierMock.new(options: { studio: boolean?, bindReceiptHandler: boolean? }?)
	local opts: { studio: boolean?, bindReceiptHandler: boolean? } = options or {}
	local self = setmetatable({}, CashierMock)
	self.Enum = Enum
	self._players = {} :: { MockPlayer }
	self._passes = {} :: { [string]: boolean }
	self._subscriptions = {} :: { [string]: boolean }
	self._failures = {} :: { [string]: { count: number, message: string } }
	self._bound = {} :: { [any]: { filtered: { [number]: any }, catchAll: any? } }
	self._pending = {} :: { PendingReceipt }
	self._purchaseCounter = 0
	self._transfers = {} :: { [string]: { sender: number, receiver: number, amount: number } }
	self._stores = {} :: { [string]: { [string]: any } }
	self.log = {} :: { string }

	local mock = self

	-- Players ---------------------------------------------------------------
	local Players = {
		PlayerAdded = MockSignal.new(),
		PlayerRemoving = MockSignal.new(),
		UserSubscriptionStatusChanged = MockSignal.new(),
	}
	function Players.GetPlayers(_self)
		return table.clone(mock._players)
	end
	function Players.GetPlayerByUserId(_self, userId: number): MockPlayer?
		for _, player in mock._players do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end

	-- MarketplaceService ----------------------------------------------------
	local MarketplaceService = {
		PromptGamePassPurchaseFinished = MockSignal.new(),
		ProcessReceipt = nil :: any,
	}
	if opts.bindReceiptHandler ~= false then
		function MarketplaceService.BindReceiptHandler(_self, receiptType, handler, filter)
			assert(type(handler) == "function", "handler must be a function")
			local slot = mock._bound[receiptType]
			if not slot then
				slot = { filtered = {}, catchAll = nil }
				mock._bound[receiptType] = slot
			end
			if filter then
				assert(
					receiptType == Enum.ReceiptType.DeveloperProduct,
					"filter is not supported for Robux transfer receipt types"
				)
				for _, productId in filter do
					if slot.filtered[productId] then
						error(`a receipt handler is already bound for product {productId}`)
					end
				end
				for _, productId in filter do
					slot.filtered[productId] = handler
				end
			else
				if slot.catchAll then
					error("a catch-all receipt handler is already bound for this receipt type")
				end
				slot.catchAll = handler
			end
			return {
				Connected = true,
				Disconnect = function(connection)
					connection.Connected = false
					if filter then
						for _, productId in filter do
							if slot.filtered[productId] == handler then
								slot.filtered[productId] = nil
							end
						end
					elseif slot.catchAll == handler then
						slot.catchAll = nil
					end
				end,
			}
		end
	end
	function MarketplaceService.UserOwnsGamePassAsync(_self, userId: number, passId: number)
		mock:_maybeFail("UserOwnsGamePassAsync")
		return mock._passes[`{userId}:{passId}`] == true
	end
	function MarketplaceService.GetUserSubscriptionStatusAsync(_self, player: MockPlayer, subscriptionId: string)
		mock:_maybeFail("GetUserSubscriptionStatusAsync")
		local active = mock._subscriptions[`{player.UserId}:{subscriptionId}`] == true
		return { IsSubscribed = active, IsRenewing = active }
	end
	function MarketplaceService.PromptRobuxTransferAsync(
		_self,
		sender: MockPlayer,
		receiverUserId: number,
		amount: number
	)
		mock:_maybeFail("PromptRobuxTransferAsync")
		assert(type(amount) == "number" and amount > 0 and amount % 1 == 0, "amount must be a positive integer")
		mock._purchaseCounter += 1
		local id = `transfer-{mock._purchaseCounter}`
		mock._transfers[id] = { sender = sender.UserId, receiver = receiverUserId, amount = amount }
		return id
	end

	-- DataStoreService ------------------------------------------------------
	local DataStoreService = {}
	function DataStoreService.GetDataStore(_self, name: string)
		local data = mock._stores[name]
		if not data then
			data = {}
			mock._stores[name] = data
		end
		local store = {}
		function store.GetAsync(_store, key: string)
			mock:_maybeFail("GetAsync")
			return deepCopy(data[key])
		end
		function store.SetAsync(_store, key: string, value: any)
			mock:_maybeFail("SetAsync")
			data[key] = deepCopy(value)
		end
		function store.UpdateAsync(_store, key: string, transform: (any) -> any)
			mock:_maybeFail("UpdateAsync")
			local nextValue = transform(deepCopy(data[key]))
			if nextValue ~= nil then
				data[key] = deepCopy(nextValue)
			end
			return deepCopy(data[key])
		end
		return store
	end

	-- RunService ------------------------------------------------------------
	local RunService = {}
	local studio = if opts.studio == nil then true else opts.studio
	function RunService.IsStudio(_self)
		return studio
	end

	self.Players = Players
	self.MarketplaceService = MarketplaceService
	self.DataStoreService = DataStoreService
	self.RunService = RunService
	self.services = {
		Players = Players,
		MarketplaceService = MarketplaceService,
		DataStoreService = DataStoreService,
		RunService = RunService,
	}
	return self
end

--------------------------------------------------------------------------------
-- Failure injection
--------------------------------------------------------------------------------

--[=[
	Makes the next `count` calls to `method` throw. Works for
	`UserOwnsGamePassAsync`, `GetUserSubscriptionStatusAsync`,
	`PromptRobuxTransferAsync`, `GetAsync`, `SetAsync` and `UpdateAsync`.
]=]
function CashierMock.FailNext(self: any, method: string, count: number?, message: string?)
	self._failures[method] = { count = count or 1, message = message or `{method} failed (mock)` }
end

function CashierMock._maybeFail(self: any, method: string)
	local failure = self._failures[method]
	if failure and failure.count > 0 then
		failure.count -= 1
		error(failure.message, 0)
	end
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

--[=[
	Adds a fake player and fires `PlayerAdded`.
]=]
function CashierMock.AddPlayer(self: any, userId: number, name: string?): MockPlayer
	local player: MockPlayer = {
		UserId = userId,
		Name = name or `Player{userId}`,
		Character = nil,
		CharacterAdded = MockSignal.new(),
		Parent = self.Players,
	}
	table.insert(self._players, player)
	self.Players.PlayerAdded:Fire(player)
	return player
end

--[=[
	Fires `PlayerRemoving` and removes the player.
]=]
function CashierMock.RemovePlayer(self: any, player: MockPlayer)
	self.Players.PlayerRemoving:Fire(player)
	local index = table.find(self._players, player)
	if index then
		table.remove(self._players, index)
	end
	player.Parent = nil
end

--[=[
	Spawns a fake character for the player and fires `CharacterAdded`.
]=]
function CashierMock.SpawnCharacter(self: any, player: MockPlayer)
	local character = { Name = player.Name, Parent = player }
	player.Character = character
	player.CharacterAdded:Fire(character)
	return character
end

--------------------------------------------------------------------------------
-- Receipts
--------------------------------------------------------------------------------

function CashierMock._handlerFor(self: any, receiptType: any, productId: number?): (any, string)
	local slot = self._bound[receiptType]
	if slot then
		if productId ~= nil and slot.filtered[productId] then
			return slot.filtered[productId], "bound"
		end
		if slot.catchAll then
			return slot.catchAll, "bound"
		end
	end
	if receiptType == Enum.ReceiptType.DeveloperProduct and self.MarketplaceService.ProcessReceipt then
		return self.MarketplaceService.ProcessReceipt, "processReceipt"
	end
	return nil, "none"
end

-- Delivers one pending receipt like Roblox does. Returns the decision name:
-- "Processed", "NotProcessedYet", "NoHandler" or "PlayerNotInServer".
function CashierMock._deliver(self: any, pending: PendingReceipt): string
	local receipt = pending.receipt
	if not self.Players:GetPlayerByUserId(receipt.PlayerId) then
		return "PlayerNotInServer"
	end
	local handler, route = self:_handlerFor(pending.receiptType, receipt.ProductId)
	if not handler then
		return "NoHandler"
	end
	pending.attempts += 1
	local ok, decision = pcall(handler, deepCopy(receipt))
	local processed = ok
		and (
			(route == "bound" and decision == (Enum.ReceiptDecision.Processed :: any))
			or (route == "processReceipt" and decision == (Enum.ProductPurchaseDecision.PurchaseGranted :: any))
		)
	if processed then
		local index = table.find(self._pending, pending)
		if index then
			table.remove(self._pending, index)
		end
		return "Processed"
	end
	return "NotProcessedYet"
end

--[=[
	@yields
	Simulates a player buying a developer product and delivers the receipt.
	Returns the decision name: "Processed", "NotProcessedYet", "NoHandler" or
	"PlayerNotInServer". Unprocessed receipts stay pending, like on Roblox,
	until `RedeliverPending` processes them.
]=]
function CashierMock.BuyProduct(
	self: any,
	player: MockPlayer | number,
	productId: number,
	price: number?
): (string, { [string]: any })
	local userId = if type(player) == "number" then player else player.UserId
	self._purchaseCounter += 1
	local receipt = {
		PurchaseId = `purchase-{self._purchaseCounter}`,
		PlayerId = userId,
		ProductId = productId,
		CurrencySpent = price or 0,
		CurrencyType = Enum.CurrencyType.Robux,
		PlaceIdWherePurchased = 0,
		ReceiptType = Enum.ReceiptType.DeveloperProduct,
	}
	local pending: PendingReceipt = { receipt = receipt, receiptType = Enum.ReceiptType.DeveloperProduct, attempts = 0 }
	table.insert(self._pending, pending)
	return self:_deliver(pending), receipt
end

--[=[
	@yields
	Delivers a receipt again, as Roblox does when a server restarts or a
	player rejoins. Pass a receipt returned by `BuyProduct`; the receipt does
	not need to be pending (Roblox can deliver a receipt twice).
]=]
function CashierMock.Redeliver(self: any, receipt: { [string]: any }): string
	for _, pending in self._pending do
		if pending.receipt.PurchaseId == receipt.PurchaseId then
			return self:_deliver(pending)
		end
	end
	local pending: PendingReceipt = { receipt = receipt, receiptType = receipt.ReceiptType, attempts = 0 }
	table.insert(self._pending, pending)
	return self:_deliver(pending)
end

--[=[
	@yields
	Retries every pending receipt whose player is in the server. Returns how
	many were processed.
]=]
function CashierMock.RedeliverPending(self: any): number
	local processed = 0
	for _, pending in table.clone(self._pending) do
		if self:_deliver(pending) == "Processed" then
			processed += 1
		end
	end
	return processed
end

--[=[
	The receipts that have not been processed yet.
]=]
function CashierMock.PendingReceipts(self: any): { { [string]: any } }
	local list = {}
	for _, pending in self._pending do
		table.insert(list, pending.receipt)
	end
	return list
end

--[=[
	Simulates a new server: drops all receipt handlers and players, keeps
	pending receipts, pass ownership and DataStores. Build a new Cashier on
	the same mock afterwards.
]=]
function CashierMock.RestartServer(self: any)
	table.clear(self._bound)
	self.MarketplaceService.ProcessReceipt = nil
	for _, player in table.clone(self._players) do
		local index = table.find(self._players, player)
		if index then
			table.remove(self._players, index)
		end
	end
	self.Players.PlayerAdded = MockSignal.new()
	self.Players.PlayerRemoving = MockSignal.new()
	self.Players.UserSubscriptionStatusChanged = MockSignal.new()
	self.MarketplaceService.PromptGamePassPurchaseFinished = MockSignal.new()
end

--------------------------------------------------------------------------------
-- Passes, subscriptions and transfers
--------------------------------------------------------------------------------

--[=[
	Sets whether a user owns a pass, without firing any event (as if they
	bought it on the website).
]=]
function CashierMock.SetPassOwned(self: any, player: MockPlayer | number, passId: number, owned: boolean?)
	local userId = if type(player) == "number" then player else player.UserId
	self._passes[`{userId}:{passId}`] = if owned == nil then true else owned
end

--[=[
	Simulates buying a pass in game: sets ownership and fires
	`PromptGamePassPurchaseFinished`.
]=]
function CashierMock.BuyPass(self: any, player: MockPlayer, passId: number)
	self:SetPassOwned(player, passId, true)
	self.MarketplaceService.PromptGamePassPurchaseFinished:Fire(player, passId, true)
end

--[=[
	Sets a player's subscription status and fires
	`Players.UserSubscriptionStatusChanged`.
]=]
function CashierMock.SetSubscribed(
	self: any,
	player: MockPlayer,
	subscriptionId: string,
	active: boolean,
	silent: boolean?
)
	self._subscriptions[`{player.UserId}:{subscriptionId}`] = active
	if not silent then
		self.Players.UserSubscriptionStatusChanged:Fire(player, subscriptionId)
	end
end

--[=[
	@yields
	Settles a transfer started with `PromptRobuxTransferAsync`: delivers the
	sender and receiver receipts. Returns both decision names.
]=]
function CashierMock.SettleTransfer(self: any, transferRequestId: string): (string, string)
	local transfer = self._transfers[transferRequestId]
	assert(transfer, `unknown transfer {transferRequestId}`)
	local function receipt(playerId: number, receiptType: any, suffix: string)
		return {
			PurchaseId = `{transferRequestId}-{suffix}`,
			PlayerId = playerId,
			CurrencySpent = transfer.amount,
			CurrencyType = Enum.CurrencyType.Robux,
			ReceiptType = receiptType,
			TransferRequestId = transferRequestId,
		}
	end
	local sent: PendingReceipt = {
		receipt = receipt(transfer.sender, Enum.ReceiptType.RobuxTransferSender, "s"),
		receiptType = Enum.ReceiptType.RobuxTransferSender,
		attempts = 0,
	}
	local received: PendingReceipt = {
		receipt = receipt(transfer.receiver, Enum.ReceiptType.RobuxTransferReceiver, "r"),
		receiptType = Enum.ReceiptType.RobuxTransferReceiver,
		attempts = 0,
	}
	table.insert(self._pending, sent)
	table.insert(self._pending, received)
	return self:_deliver(sent), self:_deliver(received)
end

--------------------------------------------------------------------------------
-- Profiles
--------------------------------------------------------------------------------

export type MockProfile = {
	Data: { [string]: any },
	LastSavedData: { [string]: any },
	saveDelay: number,
	failSaves: boolean,
	saves: number,
	Save: (self: MockProfile) -> (),
	IsActive: (self: MockProfile) -> boolean,
	EndSession: (self: MockProfile) -> (),
	[string]: any,
}

--[=[
	Creates a fake ProfileStore profile. `Save()` copies `Data` into
	`LastSavedData` after `saveDelay` seconds (default 0) unless `failSaves`
	is true. Pass `saved` to load a profile from earlier saved data, as a new
	server would.
]=]
function CashierMock.Profile(saved: { [string]: any }?, saveDelay: number?): MockProfile
	local data = deepCopy(saved or {})
	local profile = {
		Data = data,
		LastSavedData = deepCopy(data),
		saveDelay = saveDelay or 0,
		failSaves = false,
		saves = 0,
		_active = true,
	}
	function profile.Save(self: any)
		if not self._active then
			return
		end
		local snapshot = deepCopy(self.Data)
		task.delay(self.saveDelay, function()
			if self.failSaves then
				return
			end
			self.saves += 1
			self.LastSavedData = snapshot
		end)
	end
	function profile.IsActive(self: any)
		return self._active
	end
	function profile.EndSession(self: any)
		self._active = false
	end
	return (profile :: any) :: MockProfile
end

return CashierMock
