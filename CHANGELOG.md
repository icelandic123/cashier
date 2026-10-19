# Changelog

## 0.1.0

First release.

- Developer products through `MarketplaceService:BindReceiptHandler`, with a `ProcessReceipt` fallback. Each purchase is granted at most once and acknowledged only after it's saved.
- Ledgers: `ProfileLedger` (ProfileStore, ProfileService), `DataStoreLedger`, `MemoryLedger`, or your own.
- Game passes, checked on join and on in-game purchase, with an optional per-character mode.
- Subscriptions, checked on join and on `Players.UserSubscriptionStatusChanged`.
- Robux transfers: `PromptTransfer`, `OnTransferSent` and `OnTransferReceived`.
- `Cashier.Mock`, a fake marketplace for testing purchases without Robux.
