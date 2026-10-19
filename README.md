# Cashier

**Money-safe purchase handling for Roblox.** Developer products, game passes, subscriptions and Robux transfers, each granted exactly once, in one dependency-free module.

[![CI](https://github.com/icelandic123/cashier/actions/workflows/ci.yml/badge.svg)](https://github.com/icelandic123/cashier/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

```lua
local cashier = Cashier.new({
	ledger = Cashier.ProfileLedger({ getProfile = function(player) return Profiles[player] end }),
})

cashier:Product(COINS_100, function(player)
	Profiles[player].Data.Coins += 100
end)

cashier:Pass(VIP_PASS, function(player)
	player:SetAttribute("VIP", true)
end)

cashier:Start()
```

That's the whole setup. Cashier uses `MarketplaceService:BindReceiptHandler` where it exists and falls back to `ProcessReceipt` where it doesn't.

## Why this exists

Most `ProcessReceipt` code works in testing and quietly fails in production. These are the five ways it usually goes wrong, and what Cashier does about each:

| What goes wrong | What the player sees | What Cashier does |
|---|---|---|
| The grant happens in memory, then the server crashes before saving, but the receipt was already marked as granted | Paid, got nothing | Acknowledges a receipt only after the save that contains it has finished |
| The receipt arrives before the player's data has loaded, and the handler returns `PurchaseGranted` anyway | Paid, got nothing | Returns `NotProcessedYet` so Roblox retries once the data is ready |
| Roblox delivers a receipt again and the handler doesn't check `PurchaseId` | Got it twice, which inflates your economy | Records every `PurchaseId` and never grants one twice |
| The handler yields on a save, Roblox delivers the same receipt again meanwhile, and both deliveries grant | Got it twice | Lets only one delivery of a purchase run at a time |
| Passes are granted only on join, or only from `PromptGamePassPurchaseFinished` | Bought on the website and nothing happened, or bought in game and had to rejoin | Checks on join and listens for in-game purchases, with retries when the ownership check fails |

All of these are covered by the [test suite](tests/specs), which replays crashes, duplicate deliveries, DataStore outages and players leaving mid-purchase.

## Install

Pick one:

- **Wally:** `Cashier = "icelandic123/cashier@0.1.0"` under `[server-dependencies]`.
- **Model file:** download `Cashier.rbxm` from [Releases](https://github.com/icelandic123/cashier/releases) and drop it into `ServerScriptService`.
- **One file:** copy [`src/init.luau`](src/init.luau) into a ModuleScript named `Cashier`. It has no dependencies.

Cashier runs on the server only.

## Quick start with ProfileStore

```lua
local Cashier = require(ServerScriptService.Cashier)
local ProfileStore = require(ServerScriptService.ProfileStore)

local PlayerStore = ProfileStore.New("PlayerData", { Coins = 0 })
local Profiles = {}

local cashier = Cashier.new({
	ledger = Cashier.ProfileLedger({
		getProfile = function(player)
			return Profiles[player] -- nil while loading; Cashier waits
		end,
	}),
})

cashier:Product(1234567, function(player, receipt)
	Profiles[player].Data.Coins += 100
end)

cashier:Start()

-- Load profiles as usual and put them in Profiles[player].
```

The full script, with session handling, is in [`examples/ProfileStore.server.luau`](examples/ProfileStore.server.luau).

## Developer products

```lua
cashier:Product(productId, function(player, receipt)
	-- Change the player's data and return.
end)
```

The handler runs at most once per purchase. To retry later (for example, the player's inventory is full), return `false` or throw. Roblox delivers the receipt again later and the handler gets another chance.

Keep the handler short and non-yielding: change data, then return. Cashier records the purchase in the same frame and then waits for the save.

Products you don't register are left alone, so an existing `ProcessReceipt` keeps working while you migrate one product at a time. To handle every other product in one place, use `cashier:DefaultProduct(handler)`.

## Game passes

```lua
cashier:Pass(passId, function(player)
	player:SetAttribute("DoubleCoins", true)
end)

-- Re-run on every respawn, for things that live on the character:
cashier:Pass(SPEED_PASS, function(player, character)
	if character then
		character.Humanoid.WalkSpeed = 24
	end
end, { perCharacter = true })

cashier:OwnsPass(player, passId) --> true, false, or nil while still checking
```

The handler runs once per session for owners: on join if they already own the pass, or right after they buy it in game.

## Subscriptions

```lua
cashier:Subscription("EXP-1234567890", {
	onActive = function(player)
		player:SetAttribute("Member", true)
	end,
	onInactive = function(player)
		player:SetAttribute("Member", false)
	end,
})

cashier:IsSubscribed(player, "EXP-1234567890") --> true, false, or nil while still checking
```

Cashier checks each player on join and follows `Players.UserSubscriptionStatusChanged` during the session.

## Robux transfers

Roblox Plus subscribers can send another user 10 to 500 Robux through a Roblox prompt, and your experience keeps 10% of each transfer. That makes tip jars and creator support possible inside your game.

```lua
local ok, transferIdOrError = cashier:PromptTransfer(player, CREATOR_USER_ID, 100)

cashier:OnTransferSent(function(sender, receipt)
	-- Thank the sender. receipt.CurrencySpent is the amount.
end)

cashier:OnTransferReceived(function(receiver, receipt)
	-- Runs when the receiver is in one of your servers.
end)
```

Both receipts go through the same once-only pipeline as products. See [`examples/TipJar.server.luau`](examples/TipJar.server.luau).

## Choosing a ledger

The ledger is where Cashier remembers which purchases it has granted.

| Ledger | Use it when | Guarantee |
|---|---|---|
| `Cashier.ProfileLedger({ getProfile })` | You use ProfileStore, ProfileService or another session-locked data module | Exactly once. The purchase ID is saved in the player's own data, in the same write as what they bought |
| `Cashier.DataStoreLedger({ name })` | Your data isn't session-locked | Never twice. A crash between your save and Cashier's record can still lose a grant |
| `Cashier.MemoryLedger()` | Tests and Studio | Forgets everything on shutdown. Cashier warns if it's used in a live server |
| Your own table with `Check`, `Record` and `Commit` | Anything else | Whatever your storage gives you |

`ProfileLedger` keeps the last 100 purchase IDs in `profile.Data.CashierPurchases` (change with `key` and `keep`). With ProfileStore it waits until `profile.LastSavedData` contains the purchase before acknowledging it.

## Testing without spending Robux

`Cashier.Mock` is a fake `MarketplaceService`, `Players` and `DataStoreService` that runs in Studio or in [Lune](https://lune-org.github.io/docs). It lets a test do what's hard to do on purpose:

```lua
local CashierMock = require(ServerScriptService.Cashier.Mock)

local mock = CashierMock.new()
local cashier = Cashier.new({ services = mock.services, enums = mock.Enum, ledger = Cashier.MemoryLedger() })
cashier:Product(1, grantCoins)
cashier:Start()

local player = mock:AddPlayer(101)
local decision, receipt = mock:BuyProduct(player, 1) --> "Processed"
mock:Redeliver(receipt)                              -- Roblox sends it again
mock:FailNext("UpdateAsync", 3)                      -- DataStore outage
mock:RestartServer()                                 -- crash; pending receipts survive
mock:BuyPass(player, VIP_PASS)
mock:SetSubscribed(player, "EXP-1", true)
```

[`examples/MockTest.luau`](examples/MockTest.luau) walks through a crash test end to end.

## Events

```lua
cashier.Granted:Connect(function(player, receipt, kind) end)      -- kind: "product", "transferSent", "transferReceived"
cashier.Failed:Connect(function(receipt, reason, kind) end)       -- the receipt will be retried
cashier.PassOwned:Connect(function(player, passId) end)
cashier.SubscriptionChanged:Connect(function(player, subscriptionId, active) end)
```

`Granted` is a good place for analytics, for example `AnalyticsService:LogEconomyEvent`.

## Options

```lua
Cashier.new({
	ledger = ...,          -- default: DataStoreLedger({ name = "CashierPurchases" })
	debug = false,         -- print every step
	log = function(level, message) end, -- route logs elsewhere
	retries = 4,           -- attempts for each Roblox API call
	retryDelay = 1,        -- seconds, doubled per attempt
})
```

## How a receipt is handled

1. Find the player. Not in this server: retry later.
2. Ask the ledger. Data not loaded: retry later. Already granted: skip to step 4.
3. Run your handler, then record the purchase ID in the same frame.
4. Wait for the ledger to confirm the save. Confirmed: acknowledge the receipt. Not confirmed: retry later, and step 2 will skip the grant next time.

A receipt is acknowledged only at step 4, so a player is never charged without the grant being saved.

## Development

```sh
rokit install          # lune, stylua, selene, rojo
lune run tests/run     # run the test suite
stylua src tests examples
selene src examples
rojo build -o Cashier.rbxm
```

Cashier is developed with help from AI tools. Every behavior is pinned down by the test suite, which runs on every change.

## Support Cashier

Cashier is free and MIT-licensed. If it saved your game from a refund storm or a support inbox full of "I paid and got nothing", consider [sponsoring its development](https://github.com/sponsors/icelandic123). Sponsorships pay for keeping up with Roblox's commerce APIs as they change.

## License

[MIT](LICENSE)
