# Contributing

Bug reports about lost or duplicated purchases get looked at first. Please include which ledger you use and the `[Cashier]` lines from your output (set `debug = true` for more).

To work on Cashier:

1. Install [Rokit](https://github.com/rojo-rbx/rokit) and run `rokit install`.
2. Run the tests with `lune run tests/run`. Every behavior change needs a test in `tests/specs`; `Cashier.Mock` can simulate most situations.
3. Format with `stylua src tests examples` and lint with `selene src examples`.

Cashier stays a single dependency-free module, so please don't add requires to `src/init.luau`.
