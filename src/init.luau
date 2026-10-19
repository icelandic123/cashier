--!strict
--[=[
	@class Cashier

	Money-safe purchase handling for Roblox experiences.

	Cashier owns the whole server side of taking Robux: developer product
	receipts (through `MarketplaceService:BindReceiptHandler`, falling back to
	`ProcessReceipt`), game passes, subscriptions and Robux transfers. Every
	receipt is granted at most once and only acknowledged after the grant has
	been saved, so a crash, a slow DataStore or a player leaving mid-purchase
	never loses or duplicates what a player paid for.

	```lua
	local Cashier = require(path.to.Cashier)

	local cashier = Cashier.new({
		ledger = Cashier.ProfileLedger({
			getProfile = function(player) return Profiles[player] end,
		}),
	})

	cashier:Product(123456, function(player, receipt)
		Profiles[player].Data.Coins += 100
	end)

	cashier:Pass(987654, function(player)
		player:SetAttribute("VIP", true)
	end)

	cashier:Start()
	```

	Cashier is a single ModuleScript with no dependencies.
]=]

local VERSION = "0.1.0"

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

--[=[
	@interface Receipt
	@within Cashier
	.PurchaseId string -- Unique ID of this purchase. Cashier uses it to grant exactly once.
	.PlayerId number -- UserId of the player the receipt belongs to.
	.ProductId number? -- Developer product ID (developer product receipts only).
	.CurrencySpent number? -- Robux spent.
	.CurrencyType any? -- `Enum.CurrencyType`.
	.PlaceIdWherePurchased number? -- Place the purchase happened in.
	.ReceiptType any? -- `Enum.ReceiptType` (BindReceiptHandler receipts only).
	.TransferRequestId string? -- Robux transfer receipts only.

	The table Roblox hands to receipt handlers.
]=]
export type Receipt = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number?,
	CurrencySpent: number?,
	CurrencyType: any?,
	PlaceIdWherePurchased: number?,
	ReceiptType: any?,
	TransferRequestId: string?,
	[string]: any,
}

--[=[
	@type LedgerState "new" | "granted" | "unavailable"
	@within Cashier
	`"new"`: never granted. `"granted"`: granted (maybe not saved yet).
	`"unavailable"`: the player's data isn't ready, so try again later.
]=]
export type LedgerState = "new" | "granted" | "unavailable"

--[=[
	@interface Ledger
	@within Cashier
	.Check (self, player: Player, key: string) -> LedgerState -- May yield.
	.Record (self, player: Player, key: string) -> () -- Must not yield. Called right after a successful grant.
	.Commit (self, player: Player, key: string) -> boolean -- May yield. Returns true once the record (and the grant) are saved.

	Where Cashier remembers which purchases were granted. Use one of the
	built-in ledgers or pass any table with these three methods.
]=]
export type Ledger = {
	Check: (self: any, player: Player, key: string) -> LedgerState,
	Record: (self: any, player: Player, key: string) -> (),
	Commit: (self: any, player: Player, key: string) -> boolean,
	[string]: any,
}

export type ProductHandler = (player: Player, receipt: Receipt) -> boolean?
export type TransferHandler = (player: Player, receipt: Receipt) -> boolean?
export type PassHandler = (player: Player, character: Model?) -> ()

export type PassOptions = {
	--- Call the handler again every time the player's character spawns.
	perCharacter: boolean?,
}

export type SubscriptionHandlers = {
	onActive: ((player: Player) -> ())?,
	onInactive: ((player: Player) -> ())?,
}

export type Options = {
	--- Where granted purchase IDs are stored. Defaults to a DataStore ledger.
	ledger: Ledger?,
	--- Called with ("debug" | "info" | "warn" | "error", message).
	log: ((level: string, message: string) -> ())?,
	--- Print debug logs. Defaults to false.
	debug: boolean?,
	--- Dependency injection for tests. Defaults to the real services.
	services: { [string]: any }?,
	--- Dependency injection for tests. Defaults to the global `Enum`.
	enums: any?,
	--- How many times to retry a failing Roblox API call. Defaults to 4.
	retries: number?,
	--- First retry delay in seconds, doubled each attempt. Defaults to 1.
	retryDelay: number?,
}

type Connection = { Disconnect: (self: any) -> () }

--------------------------------------------------------------------------------
-- Signal (tiny, dependency-free)
--------------------------------------------------------------------------------

--[=[
	@class CashierSignal
	A minimal signal. `Connect` returns a connection with `Disconnect`.
]=]
local Signal = {}
Signal.__index = Signal

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

function Signal.new<T...>(): Signal<T...>
	return (setmetatable({ _handlers = {} }, Signal) :: any) :: Signal<T...>
end

function Signal:Connect(fn)
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

function Signal:Once(fn)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Fire(...)
	for _, handler in table.clone(self._handlers) do
		if handler.connected then
			task.spawn(handler.fn, ...)
		end
	end
end

function Signal:DisconnectAll()
	for _, handler in self._handlers do
		handler.connected = false
	end
	table.clear(self._handlers)
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function defaultLog(level: string, message: string)
	if level == "error" or level == "warn" then
		warn("[Cashier] " .. message)
	else
		print("[Cashier] " .. message)
	end
end

local function playerName(player: any): string
	local ok, name = pcall(function()
		return player.Name
	end)
	return if ok and name then tostring(name) else "?"
end

-- Calls fn(...) up to `attempts` times with exponential backoff.
-- Returns (true, result) or (false, lastError).
local function retry(attempts: number, delay: number, fn: (...any) -> any, ...: any): (boolean, any)
	local lastError
	for attempt = 1, attempts do
		local ok, result = pcall(fn, ...)
		if ok then
			return true, result
		end
		lastError = result
		if attempt < attempts then
			task.wait(delay * 2 ^ (attempt - 1))
		end
	end
	return false, lastError
end

--------------------------------------------------------------------------------
-- Ledgers
--------------------------------------------------------------------------------

export type ProfileLedgerOptions = {
	--- Returns the player's loaded profile (ProfileStore, ProfileService or
	--- anything with `.Data`). Return nil while it is still loading.
	getProfile: (player: Player) -> any,
	--- Key in `profile.Data` that holds granted purchase IDs. Defaults to "CashierPurchases".
	key: string?,
	--- How many recent purchase IDs to keep. Defaults to 100.
	keep: number?,
	--- Seconds to wait for the save before giving up (the receipt is retried later). Defaults to 30.
	saveTimeout: number?,
	--- Seconds between save checks. Defaults to 0.5.
	pollInterval: number?,
}

local function profileIsActive(profile: any): boolean
	local isActive = profile.IsActive
	if type(isActive) == "function" then
		local ok, active = pcall(isActive, profile)
		return ok and active == true
	end
	return true
end

local function listHas(list: any, key: string): boolean
	return type(list) == "table" and table.find(list, key) ~= nil
end

--[=[
	@within Cashier
	@return Ledger

	Stores granted purchase IDs inside the player's own profile data, so the
	grant and its record are saved together in one write. This is the safest
	ledger: a purchase is acknowledged only after `profile.LastSavedData`
	(ProfileStore) shows it was saved.

	Works with ProfileStore out of the box. For other session-locked data
	systems, give the profile a `LastSavedData` table and a `Save` method, or
	write a custom ledger.
]=]
local function ProfileLedger(options: ProfileLedgerOptions): Ledger
	assert(type(options) == "table" and type(options.getProfile) == "function", "ProfileLedger needs getProfile")
	local field = options.key or "CashierPurchases"
	local keep = options.keep or 100
	local saveTimeout = options.saveTimeout or 30
	local pollInterval = options.pollInterval or 0.5

	local ledger = {}

	local function profileFor(player: Player): any
		local ok, profile = pcall(options.getProfile, player)
		if not ok or type(profile) ~= "table" or type(profile.Data) ~= "table" then
			return nil
		end
		if not profileIsActive(profile) then
			return nil
		end
		return profile
	end

	function ledger.Check(_self, player: Player, key: string): LedgerState
		local profile = profileFor(player)
		if not profile then
			return "unavailable"
		end
		return if listHas(profile.Data[field], key) then "granted" else "new"
	end

	function ledger.Record(_self, player: Player, key: string)
		local profile = profileFor(player)
		assert(profile, "profile disappeared between Check and Record")
		local list = profile.Data[field]
		if type(list) ~= "table" then
			list = {}
			profile.Data[field] = list
		end
		if not table.find(list, key) then
			table.insert(list, key)
		end
		while #list > keep do
			table.remove(list, 1)
		end
	end

	function ledger.Commit(_self, player: Player, key: string): boolean
		local profile = profileFor(player)
		if not profile then
			return false
		end
		-- Without LastSavedData (ProfileService, custom systems) saves can't be
		-- observed: ask for a save and trust the session lock.
		if profile.LastSavedData == nil then
			if type(profile.Save) == "function" then
				pcall(profile.Save, profile)
			end
			return true
		end
		local function saved(): boolean
			local lastSaved = profile.LastSavedData
			return type(lastSaved) == "table" and listHas(lastSaved[field], key)
		end
		if saved() then
			return true
		end
		if type(profile.Save) == "function" then
			pcall(profile.Save, profile)
		end
		local waited = 0
		while waited < saveTimeout do
			waited += task.wait(pollInterval)
			if saved() then
				return true
			end
			if not profileIsActive(profile) then
				-- Session ended. If the final save included the key we already
				-- returned above; otherwise let Roblox redeliver the receipt.
				return saved()
			end
		end
		return false
	end

	return ledger
end

export type DataStoreLedgerOptions = {
	--- DataStore name. Defaults to "CashierPurchases".
	name: string?,
	--- DataStoreService to use (for tests).
	dataStoreService: any?,
	retries: number?,
	retryDelay: number?,
}

--[=[
	@within Cashier
	@return Ledger

	Stores one DataStore key per granted purchase. Use it when your player data
	isn't session-locked. It prevents double grants, but because the record and
	your player data are two separate writes, a server crash in between can
	still lose a grant. Prefer `ProfileLedger` when you can.
]=]
local function DataStoreLedger(options: DataStoreLedgerOptions?): Ledger
	local opts: DataStoreLedgerOptions = options or {}
	local name = opts.name or "CashierPurchases"
	local retries = opts.retries or 4
	local retryDelay = opts.retryDelay or 1
	local store: any = nil
	local granted: { [string]: boolean } = {}

	local function getStore()
		if not store then
			local service = opts.dataStoreService or (game :: any):GetService("DataStoreService")
			store = service:GetDataStore(name)
		end
		return store
	end

	local ledger = {}

	function ledger.Check(_self, _player: Player, key: string): LedgerState
		if granted[key] ~= nil then
			return "granted"
		end
		local ok, value = retry(retries, retryDelay, function()
			return getStore():GetAsync(key)
		end)
		if not ok then
			return "unavailable"
		end
		if value ~= nil then
			granted[key] = true
			return "granted"
		end
		return "new"
	end

	function ledger.Record(_self, _player: Player, key: string)
		-- Remember in memory right away so this server never grants twice,
		-- even if the DataStore write below fails and the receipt comes back.
		granted[key] = false
	end

	function ledger.Commit(_self, player: Player, key: string): boolean
		if granted[key] == true then
			return true
		end
		local userId = (player :: any).UserId
		local ok = retry(retries, retryDelay, function()
			return getStore():UpdateAsync(key, function(current)
				return current or { userId = userId, grantedAt = os.time() }
			end)
		end)
		if ok then
			granted[key] = true
		end
		return ok
	end

	return ledger
end

--[=[
	@within Cashier
	@return Ledger

	Keeps granted purchase IDs in memory only. For tests and Studio. Cashier
	warns if you use it in a live server.
]=]
local function MemoryLedger(): Ledger
	local granted: { [string]: boolean } = {}
	local ledger = { _memory = true }
	function ledger.Check(_self, _player: Player, key: string): LedgerState
		return if granted[key] then "granted" else "new"
	end
	function ledger.Record(_self, _player: Player, key: string)
		granted[key] = true
	end
	function ledger.Commit(_self, _player: Player, _key: string): boolean
		return true
	end
	return ledger
end

--------------------------------------------------------------------------------
-- Cashier
--------------------------------------------------------------------------------

local Cashier = {}
Cashier.__index = Cashier
Cashier.VERSION = VERSION
Cashier.ProfileLedger = ProfileLedger
Cashier.DataStoreLedger = DataStoreLedger
Cashier.MemoryLedger = MemoryLedger
Cashier.Signal = Signal

export type Cashier = typeof(setmetatable(
	{} :: {
		--- Fires after a purchase is granted: (player, receipt, kind).
		Granted: Signal<Player, Receipt, string>,
		--- Fires when a receipt couldn't be granted yet: (receipt, reason, kind).
		Failed: Signal<Receipt, string, string>,
		--- Fires when a player gains a pass during the session or on join: (player, passId).
		PassOwned: Signal<Player, number>,
		--- Fires when a subscription turns on or off: (player, subscriptionId, active).
		SubscriptionChanged: Signal<Player, string, boolean>,
		_options: Options,
		_ledger: Ledger,
		_services: { [string]: any },
		_enums: any,
		_retries: number,
		_retryDelay: number,
		_products: { [number]: ProductHandler },
		_defaultProduct: ProductHandler?,
		_transferIn: TransferHandler?,
		_transferOut: TransferHandler?,
		_passes: { [number]: { handler: PassHandler, options: PassOptions } },
		_subscriptions: { [string]: SubscriptionHandlers },
		_passState: { [Player]: { [number]: boolean } },
		_subState: { [Player]: { [string]: boolean } },
		_characterConnections: { [Player]: { Connection } },
		_inflight: { [string]: boolean },
		_connections: { Connection },
		_receiptConnections: { [string]: Connection },
		_usingProcessReceipt: boolean,
		_started: boolean,
		_destroyed: boolean,
	},
	Cashier
))

--[=[
	Creates a Cashier. Register products, passes and subscriptions, then call
	`Start`.
]=]
function Cashier.new(options: Options?): Cashier
	local opts: Options = options or {}
	local services = opts.services or {}
	local self = setmetatable({
		Granted = Signal.new(),
		Failed = Signal.new(),
		PassOwned = Signal.new(),
		SubscriptionChanged = Signal.new(),
		_options = opts,
		_ledger = nil :: any,
		_services = services,
		_enums = opts.enums or (Enum :: any),
		_retries = opts.retries or 4,
		_retryDelay = opts.retryDelay or 1,
		_products = {},
		_defaultProduct = nil,
		_transferIn = nil,
		_transferOut = nil,
		_passes = {},
		_subscriptions = {},
		_passState = {},
		_subState = {},
		_characterConnections = {},
		_inflight = {},
		_connections = {},
		_receiptConnections = {},
		_usingProcessReceipt = false,
		_started = false,
		_destroyed = false,
	}, Cashier)

	self._ledger = opts.ledger
		or DataStoreLedger({
			dataStoreService = services.DataStoreService,
			retries = self._retries,
			retryDelay = self._retryDelay,
		})
	return self
end

function Cashier._log(self: Cashier, level: string, message: string)
	if level == "debug" and not self._options.debug then
		return
	end
	local log = self._options.log or defaultLog
	log(level, message)
end

function Cashier._service(self: Cashier, name: string): any
	local service = self._services[name]
	if service == nil then
		service = (game :: any):GetService(name)
		self._services[name] = service
	end
	return service
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

--[=[
	Grants a developer product. `grant(player, receipt)` runs at most once per
	purchase. Return `false` (or throw) to retry the receipt later, for example
	when the player's data isn't ready.

	Keep `grant` quick and non-yielding: change the player's data and return.
	Cashier saves and acknowledges the receipt after it returns.
]=]
function Cashier.Product(self: Cashier, productId: number, grant: ProductHandler): Cashier
	assert(type(productId) == "number", "Product: productId must be a number")
	assert(type(grant) == "function", "Product: grant must be a function")
	assert(self._products[productId] == nil, `Product {productId} is already registered`)
	self._products[productId] = grant
	if self._started then
		self:_bindProductReceipts()
	end
	return self
end

--[=[
	Grants any developer product that has no `Product` handler. Without it,
	unknown products are left for your own `ProcessReceipt` (or retried later),
	never acknowledged blindly.
]=]
function Cashier.DefaultProduct(self: Cashier, grant: ProductHandler): Cashier
	assert(type(grant) == "function", "DefaultProduct: grant must be a function")
	self._defaultProduct = grant
	if self._started then
		self:_bindProductReceipts()
	end
	return self
end

--[=[
	Runs `onOwned(player)` once per session for every player who owns the
	pass, whether they bought it earlier or buy it now. With
	`{ perCharacter = true }` it also runs on every respawn as
	`onOwned(player, character)`.
]=]
function Cashier.Pass(self: Cashier, passId: number, onOwned: PassHandler, options: PassOptions?): Cashier
	assert(type(passId) == "number", "Pass: passId must be a number")
	assert(type(onOwned) == "function", "Pass: onOwned must be a function")
	assert(self._passes[passId] == nil, `Pass {passId} is already registered`)
	self._passes[passId] = { handler = onOwned, options = options or {} }
	if self._started then
		for _, player in self:_service("Players"):GetPlayers() do
			task.spawn(self._checkPass, self, player, passId)
		end
	end
	return self
end

--[=[
	Tracks a subscription. `onActive(player)` runs when a player has it (on
	join or after subscribing); `onInactive(player)` runs when it lapses or is
	cancelled during the session.
]=]
function Cashier.Subscription(self: Cashier, subscriptionId: string, handlers: SubscriptionHandlers): Cashier
	assert(type(subscriptionId) == "string", "Subscription: subscriptionId must be a string")
	assert(type(handlers) == "table", "Subscription: handlers must be a table")
	assert(self._subscriptions[subscriptionId] == nil, `Subscription {subscriptionId} is already registered`)
	self._subscriptions[subscriptionId] = handlers
	if self._started then
		for _, player in self:_service("Players"):GetPlayers() do
			task.spawn(self._checkSubscription, self, player, subscriptionId)
		end
	end
	return self
end

--[=[
	Handles Robux a player received through `PromptRobuxTransferAsync`, at
	most once per transfer.
]=]
function Cashier.OnTransferReceived(self: Cashier, handler: TransferHandler): Cashier
	assert(type(handler) == "function", "OnTransferReceived: handler must be a function")
	self._transferIn = handler
	if self._started then
		self:_bindTransferReceipts()
	end
	return self
end

--[=[
	Handles Robux a player sent through `PromptRobuxTransferAsync`, at most
	once per transfer. Use it to thank or reward the sender.
]=]
function Cashier.OnTransferSent(self: Cashier, handler: TransferHandler): Cashier
	assert(type(handler) == "function", "OnTransferSent: handler must be a function")
	self._transferOut = handler
	if self._started then
		self:_bindTransferReceipts()
	end
	return self
end

--------------------------------------------------------------------------------
-- Receipts
--------------------------------------------------------------------------------

local KIND_PRODUCT = "product"
local KIND_TRANSFER_IN = "transferReceived"
local KIND_TRANSFER_OUT = "transferSent"

local function ledgerKey(kind: string, receipt: Receipt): string
	if kind == KIND_PRODUCT then
		return tostring(receipt.PurchaseId)
	end
	local id = receipt.TransferRequestId or receipt.PurchaseId
	return (if kind == KIND_TRANSFER_IN then "tx-in:" else "tx-out:") .. tostring(id)
end

-- Returns true when the receipt is granted and saved.
function Cashier._process(self: Cashier, kind: string, receipt: Receipt, handler: ProductHandler): boolean
	local key = ledgerKey(kind, receipt)
	local players = self:_service("Players")
	local player = players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		self.Failed:Fire(receipt, "player is not in this server", kind)
		self:_log("debug", `{key}: player {receipt.PlayerId} is not in this server, will retry`)
		return false
	end

	local ledger = self._ledger
	local okCheck, state = pcall(ledger.Check, ledger, player, key)
	if not okCheck then
		self.Failed:Fire(receipt, `ledger check failed: {state}`, kind)
		self:_log("warn", `{key}: ledger check failed: {state}`)
		return false
	end

	if state == "unavailable" then
		self.Failed:Fire(receipt, "player data is not ready", kind)
		self:_log("debug", `{key}: data for {playerName(player)} is not ready, will retry`)
		return false
	elseif state == "new" then
		local okGrant, result = pcall(handler, player, receipt)
		if not okGrant then
			self.Failed:Fire(receipt, `grant errored: {result}`, kind)
			self:_log("error", `{key}: grant for {playerName(player)} errored: {result}`)
			return false
		end
		if result == false then
			self.Failed:Fire(receipt, "grant returned false", kind)
			self:_log("debug", `{key}: grant for {playerName(player)} deferred`)
			return false
		end
		-- Still the same server frame as the grant: nothing can save the grant
		-- without the record.
		local okRecord, recordError = pcall(ledger.Record, ledger, player, key)
		if not okRecord then
			self:_log("error", `{key}: granted but could not record: {recordError}`)
		end
		self.Granted:Fire(player, receipt, kind)
		self:_log("debug", `{key}: granted to {playerName(player)}`)
	elseif state ~= "granted" then
		self:_log("error", `{key}: ledger returned unknown state {tostring(state)}`)
		return false
	end

	local okCommit, committed = pcall(ledger.Commit, ledger, player, key)
	if okCommit and committed then
		return true
	end
	local reason = if okCommit then "save not confirmed yet" else `commit errored: {committed}`
	self.Failed:Fire(receipt, reason, kind)
	self:_log("warn", `{key}: {reason}, will retry`)
	return false
end

-- Wraps _process with an in-flight guard and turns its result into a decision.
function Cashier._handle(self: Cashier, kind: string, receipt: Receipt, handler: ProductHandler?): boolean
	if not handler then
		self.Failed:Fire(receipt, "no handler registered", kind)
		self:_log("warn", `no handler for {kind} receipt (product {tostring(receipt.ProductId)}), will retry`)
		return false
	end
	local key = ledgerKey(kind, receipt)
	if self._inflight[key] then
		-- Roblox redelivered while we're still working on it.
		return false
	end
	self._inflight[key] = true
	local ok, processed = pcall(self._process, self, kind, receipt, handler)
	self._inflight[key] = nil
	if not ok then
		self:_log("error", `{key}: unexpected error: {processed}`)
		return false
	end
	return processed
end

function Cashier._productHandlerFor(self: Cashier, productId: number?): ProductHandler?
	if productId ~= nil and self._products[productId] then
		return self._products[productId]
	end
	return self._defaultProduct
end

local function canBind(marketplace: any): boolean
	local ok, method = pcall(function()
		return marketplace.BindReceiptHandler
	end)
	return ok and method ~= nil
end

function Cashier._bindProductReceipts(self: Cashier)
	local marketplace = self:_service("MarketplaceService")
	local enums = self._enums

	if self._receiptConnections.product then
		self._receiptConnections.product:Disconnect()
		self._receiptConnections.product = nil
	end

	if canBind(marketplace) then
		local filter: { number }? = nil
		if not self._defaultProduct then
			filter = {}
			for productId in self._products do
				table.insert(filter :: { number }, productId)
			end
			if #(filter :: { number }) == 0 then
				return
			end
		end
		local handler = function(receipt: Receipt)
			local granted = self:_handle(KIND_PRODUCT, receipt, self:_productHandlerFor(receipt.ProductId))
			return if granted then enums.ReceiptDecision.Processed else enums.ReceiptDecision.NotProcessedYet
		end
		local ok, connection = pcall(function()
			if filter then
				return marketplace:BindReceiptHandler(enums.ReceiptType.DeveloperProduct, handler, filter)
			end
			return marketplace:BindReceiptHandler(enums.ReceiptType.DeveloperProduct, handler)
		end)
		if ok then
			self._receiptConnections.product = connection
			return
		end
		self:_log("warn", `BindReceiptHandler failed ({connection}); falling back to ProcessReceipt`)
	end

	self._usingProcessReceipt = true
	marketplace.ProcessReceipt = function(receipt: Receipt)
		local granted = self:_handle(KIND_PRODUCT, receipt, self:_productHandlerFor(receipt.ProductId))
		return if granted
			then enums.ProductPurchaseDecision.PurchaseGranted
			else enums.ProductPurchaseDecision.NotProcessedYet
	end
end

function Cashier._bindTransferReceipts(self: Cashier)
	local marketplace = self:_service("MarketplaceService")
	local enums = self._enums
	if not canBind(marketplace) then
		self:_log("warn", "this server has no BindReceiptHandler, so Robux transfer receipts can't be handled")
		return
	end
	local pairs_ = {
		{ name = "transferIn", kind = KIND_TRANSFER_IN, receiptType = enums.ReceiptType.RobuxTransferReceiver },
		{ name = "transferOut", kind = KIND_TRANSFER_OUT, receiptType = enums.ReceiptType.RobuxTransferSender },
	}
	for _, spec in pairs_ do
		local handler = if spec.name == "transferIn" then self._transferIn else self._transferOut
		if handler and not self._receiptConnections[spec.name] then
			local ok, connection = pcall(function()
				return marketplace:BindReceiptHandler(spec.receiptType, function(receipt: Receipt)
					local current = if spec.name == "transferIn" then self._transferIn else self._transferOut
					local granted = self:_handle(spec.kind, receipt, current)
					return if granted then enums.ReceiptDecision.Processed else enums.ReceiptDecision.NotProcessedYet
				end)
			end)
			if ok then
				self._receiptConnections[spec.name] = connection
			else
				self:_log("error", `could not bind {spec.kind} receipts: {connection}`)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Passes
--------------------------------------------------------------------------------

function Cashier._grantPass(self: Cashier, player: Player, passId: number)
	local states = self._passState[player]
	if not states or states[passId] then
		return
	end
	states[passId] = true
	local pass = self._passes[passId]
	if not pass then
		return
	end
	self.PassOwned:Fire(player, passId)
	local ok, err = pcall(pass.handler, player, nil)
	if not ok then
		self:_log("error", `pass {passId} handler errored for {playerName(player)}: {err}`)
	end
	if pass.options.perCharacter then
		local characterAdded = (player :: any).CharacterAdded
		if characterAdded then
			local connection = characterAdded:Connect(function(character)
				local okCharacter, errCharacter = pcall(pass.handler, player, character)
				if not okCharacter then
					self:_log("error", `pass {passId} handler errored on respawn: {errCharacter}`)
				end
			end)
			local list = self._characterConnections[player]
			if list then
				table.insert(list, connection)
			end
		end
		local character = (player :: any).Character
		if character then
			local okCharacter, errCharacter = pcall(pass.handler, player, character)
			if not okCharacter then
				self:_log("error", `pass {passId} handler errored for current character: {errCharacter}`)
			end
		end
	end
end

function Cashier._checkPass(self: Cashier, player: Player, passId: number)
	local marketplace = self:_service("MarketplaceService")
	local players = self:_service("Players")
	local delay = self._retryDelay
	while not self._destroyed and self._passState[player] and not self._passState[player][passId] do
		local ok, owns = retry(self._retries, self._retryDelay, function()
			return marketplace:UserOwnsGamePassAsync((player :: any).UserId, passId)
		end)
		if ok then
			if owns then
				self:_grantPass(player, passId)
			elseif self._passState[player] and self._passState[player][passId] == nil then
				self._passState[player][passId] = false
			end
			return
		end
		self:_log("warn", `could not check pass {passId} for {playerName(player)}: {owns}; retrying`)
		task.wait(delay)
		delay = math.min(delay * 2, 60)
		if players:GetPlayerByUserId((player :: any).UserId) ~= player then
			return
		end
	end
end

--[=[
	Whether the player owns the pass, as far as this server knows. Returns
	`nil` until the first ownership check finishes.
]=]
function Cashier.OwnsPass(self: Cashier, player: Player, passId: number): boolean?
	local states = self._passState[player]
	return if states then states[passId] else nil
end

--------------------------------------------------------------------------------
-- Subscriptions
--------------------------------------------------------------------------------

function Cashier._setSubscription(self: Cashier, player: Player, subscriptionId: string, active: boolean)
	local states = self._subState[player]
	if not states then
		return
	end
	local previous = states[subscriptionId]
	states[subscriptionId] = active
	if previous == active or (previous == nil and not active) then
		return
	end
	self.SubscriptionChanged:Fire(player, subscriptionId, active)
	local handlers = self._subscriptions[subscriptionId]
	local fn = if active then handlers.onActive else handlers.onInactive
	if fn then
		local ok, err = pcall(fn, player)
		if not ok then
			self:_log("error", `subscription {subscriptionId} handler errored for {playerName(player)}: {err}`)
		end
	end
end

function Cashier._checkSubscription(self: Cashier, player: Player, subscriptionId: string)
	local marketplace = self:_service("MarketplaceService")
	local ok, status = retry(self._retries, self._retryDelay, function()
		return marketplace:GetUserSubscriptionStatusAsync(player, subscriptionId)
	end)
	if not ok then
		self:_log("warn", `could not check subscription {subscriptionId} for {playerName(player)}: {status}`)
		return
	end
	if not self._subState[player] then
		return
	end
	self:_setSubscription(player, subscriptionId, type(status) == "table" and status.IsSubscribed == true)
end

--[=[
	Whether the player's subscription is active, as far as this server knows.
	Returns `nil` until the first check finishes.
]=]
function Cashier.IsSubscribed(self: Cashier, player: Player, subscriptionId: string): boolean?
	local states = self._subState[player]
	return if states then states[subscriptionId] else nil
end

--------------------------------------------------------------------------------
-- Robux transfers
--------------------------------------------------------------------------------

--[=[
	@yields
	Prompts `sender` to send `amount` Robux (10 to 500) to `receiverUserId`.
	Returns `(true, transferRequestId)` or `(false, errorMessage)`. Your
	experience earns 10% of each transfer.
]=]
function Cashier.PromptTransfer(
	self: Cashier,
	sender: Player,
	receiverUserId: number,
	amount: number
): (boolean, string)
	if type(amount) ~= "number" or amount % 1 ~= 0 or amount < 10 or amount > 500 then
		return false, "amount must be a whole number from 10 to 500"
	end
	if type(receiverUserId) ~= "number" or receiverUserId <= 0 or receiverUserId % 1 ~= 0 then
		return false, "receiverUserId must be a positive whole number"
	end
	if receiverUserId == (sender :: any).UserId then
		return false, "a player can't transfer Robux to themselves"
	end
	local marketplace = self:_service("MarketplaceService")
	local ok, result = pcall(function()
		return marketplace:PromptRobuxTransferAsync(sender, receiverUserId, amount)
	end)
	if not ok then
		return false, tostring(result)
	end
	return true, tostring(result)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Cashier._onPlayerAdded(self: Cashier, player: Player)
	if self._passState[player] then
		return
	end
	self._passState[player] = {}
	self._subState[player] = {}
	self._characterConnections[player] = {}
	for passId in self._passes do
		task.spawn(self._checkPass, self, player, passId)
	end
	for subscriptionId in self._subscriptions do
		task.spawn(self._checkSubscription, self, player, subscriptionId)
	end
end

function Cashier._onPlayerRemoving(self: Cashier, player: Player)
	for _, connection in self._characterConnections[player] or {} do
		connection:Disconnect()
	end
	self._characterConnections[player] = nil
	self._passState[player] = nil
	self._subState[player] = nil
end

--[=[
	Starts handling receipts and players. Call it once, after registering
	your products (you can still register more afterwards).
]=]
function Cashier.Start(self: Cashier): Cashier
	assert(not self._started, "Cashier:Start() was already called")
	assert(not self._destroyed, "Cashier was destroyed")
	self._started = true

	if (self._ledger :: any)._memory then
		local okStudio, isStudio = pcall(function()
			return self:_service("RunService"):IsStudio()
		end)
		if okStudio and not isStudio then
			self:_log(
				"warn",
				"MemoryLedger forgets purchases on shutdown; use ProfileLedger or DataStoreLedger in live games"
			)
		end
	end

	local players = self:_service("Players")
	local marketplace = self:_service("MarketplaceService")

	table.insert(
		self._connections,
		players.PlayerAdded:Connect(function(player)
			self:_onPlayerAdded(player)
		end)
	)
	table.insert(
		self._connections,
		players.PlayerRemoving:Connect(function(player)
			self:_onPlayerRemoving(player)
		end)
	)
	table.insert(
		self._connections,
		marketplace.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
			if wasPurchased and self._passes[passId] then
				if self._passState[player] then
					self:_grantPass(player, passId)
				end
			end
		end)
	)
	local okSignal, subscriptionSignal = pcall(function()
		return players.UserSubscriptionStatusChanged
	end)
	if okSignal and subscriptionSignal then
		table.insert(
			self._connections,
			subscriptionSignal:Connect(function(player, subscriptionId)
				if self._subscriptions[subscriptionId] and self._subState[player] then
					self:_checkSubscription(player, subscriptionId)
				end
			end)
		)
	end

	for _, player in players:GetPlayers() do
		task.spawn(self._onPlayerAdded, self, player)
	end

	self:_bindProductReceipts()
	if self._transferIn or self._transferOut then
		self:_bindTransferReceipts()
	end
	self:_log("debug", `started (v{VERSION})`)
	return self
end

--[=[
	Stops handling receipts and disconnects everything.
]=]
function Cashier.Destroy(self: Cashier)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	for _, connection in self._receiptConnections do
		connection:Disconnect()
	end
	for player in self._characterConnections do
		self:_onPlayerRemoving(player)
	end
	table.clear(self._connections)
	table.clear(self._receiptConnections)
	if self._usingProcessReceipt then
		pcall(function()
			self:_service("MarketplaceService").ProcessReceipt = nil
		end)
	end
	self.Granted:DisconnectAll()
	self.Failed:DisconnectAll()
	self.PassOwned:DisconnectAll()
	self.SubscriptionChanged:DisconnectAll()
end

return Cashier
