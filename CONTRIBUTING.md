# Contributing

Issues and pull requests are welcome. Code, comments, documentation and commit messages are written in English.

1. Open an issue first for anything larger than a small fix.
2. Run the two commands of the README's Development section (`swift test` and the iOS `xcodebuild` build) before you push, as CI does.
3. Keep a pull request focused on one change, with tests for the behavior it adds or fixes.
4. Document every public type and function you add.

The server decides who has access: the library runs the purchase flow, reports the result and never decides entitlements. Changes to the bridge messages must follow the [bridge contract](https://github.com/pmakerhq/tillbell-rails/blob/main/docs/bridge-contract.md) of tillbell-rails.

To report a security problem, follow [SECURITY.md](SECURITY.md) instead of opening an issue.
