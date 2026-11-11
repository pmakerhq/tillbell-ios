# Tillbell for iOS

[![CI](https://github.com/pmakerhq/tillbell-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/pmakerhq/tillbell-ios/actions/workflows/ci.yml)
[![Swift Package Manager](https://img.shields.io/badge/SwiftPM-compatible-orange.svg)](#installation)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**A [Hotwire Native](https://native.hotwired.dev) bridge component that runs the StoreKit 2 purchase flow for subscriptions sold from a Rails paywall.**

This is the iOS half of Tillbell. The server half is [tillbell-rails](https://github.com/pmakerhq/tillbell-rails); the Android half is [tillbell-android](https://github.com/pmakerhq/tillbell-android). The same paywall page talks to both apps with the same messages.

```swift
import HotwireNative
import Tillbell

Hotwire.registerBridgeComponents([TillbellComponent.self])
```

That one line is all the native setup there is.

> [!WARNING]
> **Status: v0.2, early.** The component implements the whole [bridge contract](https://github.com/pmakerhq/tillbell-rails/blob/main/docs/bridge-contract.md) and is unit tested, but it has not been verified with real App Store purchases yet. It needs tillbell-rails 0.6 or later, the first version that verifies App Store transactions (see its [App Store setup](https://github.com/pmakerhq/tillbell-rails#app-store-setup)). Expect changes before 1.0.

## Table of contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
- [Registration](#registration)
- [How it behaves](#how-it-behaves)
- [From Google Play to the App Store](#from-google-play-to-the-app-store)
- [Testing your paywall](#testing-your-paywall)
- [Development](#development)
- [The Tillbell family](#the-tillbell-family)
- [Contributing](#contributing)
- [License](#license)

## What it does

Your paywall is a normal server-rendered Rails page, with the `tillbell` Stimulus controller installed by tillbell-rails. Inside your Hotwire Native app, the page asks this component to:

1. look up the localized price of each plan shown on the paywall (`products`);
2. open the App Store purchase sheet for the selected subscription, tagged with the identifier created by Rails (`appAccountToken`), plan changes included (`purchase`);
3. list the subscriptions the App Store account is entitled to (`restore`);
4. open the App Store sheet where the customer manages their subscriptions (`manage`).

The page then posts the signed transaction to your Rails app, which verifies it and unlocks the subscription. All business logic (who is subscribed, until when, in which state) stays in Rails.

## Requirements

| | Version | Why |
|---|---|---|
| iOS | 15.0 | StoreKit 2 needs iOS 15. |
| Hotwire Native iOS | 1.3.1 or later (1.x) | The component extends its `BridgeComponent`. |
| tillbell-rails | 0.6 or later | The first version that verifies App Store transactions and accepts `pending` without a token. |
| Xcode | 16 or later | The package uses Swift tools 6.0. |

No other dependency.

## Installation

Tillbell is a Swift package, referenced straight from this repository.

**In Xcode:** *File › Add Package Dependencies…*, paste the repository URL and add the `Tillbell` library to your app target:

```
https://github.com/pmakerhq/tillbell-ios
```

Choose *Up to Next Minor Version* from `0.2.0`: before 1.0, a minor release can change the API or require a newer tillbell-rails, so you move to it on purpose.

**In a `Package.swift`:**

```swift
dependencies: [
    .package(url: "https://github.com/pmakerhq/tillbell-ios", .upToNextMinor(from: "0.2.0")),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Tillbell", package: "tillbell-ios")]),
]
```

Then enable the **In-App Purchase** capability of your app target, and create your auto-renewable subscriptions in App Store Connect.

### Releasing

Push a `X.Y.Z` tag (semantic versioning, no `v` prefix, as Swift Package Manager expects) on `main` after CI passes. There is nothing to upload: Xcode resolves versions from the tags. A published tag is never moved, so a fix ships as a new tag.

## Registration

Register the component with Hotwire next to your other bridge components, before the first page loads, usually in your `AppDelegate`:

```swift
import HotwireNative
import Tillbell

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Hotwire.registerBridgeComponents([
            ExternalOfferComponent.self, // your own components
            TillbellComponent.self,
        ])
        return true
    }
}
```

Registering the component is what enables the paywall: Hotwire Native lists `tillbell` in the app's user agent, and the page only connects its controller when it finds it. Without it, the paywall shows its fallback and never sends a message.

The component coexists with any other bridge component and with other StoreKit code in the same app.

## How it behaves

- **The server decides.** The component reports what the App Store says and nothing else. It never grants access and never derives an identifier on the device: `obfuscatedAccountId`, the UUID generated by Rails, is passed to StoreKit unchanged as the `appAccountToken`, so every transaction can be tied back to your customer.
- **The purchase token is the signed transaction**, the JWS of StoreKit's `VerificationResult`. The server verifies its signature and reads the transaction, the original transaction id and the `appAccountToken` from it. Transactions StoreKit cannot verify are never reported.
- **Prices come from the App Store**: the `displayPrice` of the `Product`, formatted for the customer's storefront. Plans the App Store does not know are left out of the reply, and the page disables them.
- **Transactions are finished on the device.** On iOS only the app can finish a transaction, so the component finishes it right after StoreKit returns it, and finishes the subscription transactions that arrive later (an Ask to Buy approval, a purchase interrupted when the app was killed) from `Transaction.updates`, once the paywall has sent its first message; until then StoreKit keeps them. Other product types are left to your own StoreKit code. Finishing does not grant access, and loses nothing: `restore` still lists the subscription.
- **Already subscribed** answers `already_owned` without opening the sheet, as on Google Play, and the page restores the purchase.
- **Plan changes** need nothing from the device. When the page sends `oldPurchaseToken` and `replacementMode`, both are checked and the App Store replaces the subscription of the same subscription group: at once for an upgrade, at the next renewal for a downgrade, by the levels you set in App Store Connect. The reply carries the transaction StoreKit returns.
- **Ask to Buy** (and other purchases waiting for approval) replies `pending` with the `productId` and no `purchaseToken`: StoreKit gives none until the purchase is approved. The paywall shows its pending message, and the server records the purchase from App Store Server Notifications once it is approved.
- **Every request gets one reply**, including errors and malformed requests, so the page never waits forever. The purchase in flight outlives the page: if the customer leaves it while the sheet is open, the transaction is still finished, and `restore` returns it.
- **Restore** reads `Transaction.currentEntitlements` and never shows an Apple Account sign-in prompt. It lists the subscriptions the account bought, not those shared with it through Family Sharing: they carry another customer's `appAccountToken`.

## From Google Play to the App Store

The [bridge contract](https://github.com/pmakerhq/tillbell-rails/blob/main/docs/bridge-contract.md) was written for Google Play first. On iOS, its fields map to StoreKit 2 like this:

| Contract | StoreKit 2 |
|---|---|
| `productId` | App Store product identifier of an auto-renewable subscription |
| `basePlanId` | Must be `null`: the App Store has no base plans, each duration is its own product. A plan with a base plan is left out of `products`, and `purchase` replies `error`. |
| `formattedPrice` | `Product.displayPrice` |
| `obfuscatedAccountId` | `Product.PurchaseOption.appAccountToken` (must be a UUID) |
| `purchaseToken` | `VerificationResult<Transaction>.jwsRepresentation` |
| `oldPurchaseToken`, `replacementMode` | Checked, then handled by the App Store from the subscription group |
| `purchased` | `.success(.verified)` |
| `pending` | `.pending` (Ask to Buy), without `purchaseToken` |
| `canceled` | `.userCancelled` |
| `already_owned` | A current entitlement, bought by this account, to the requested product |
| `unavailable` | `AppStore.canMakePayments` is false, `notAvailableInStorefront`, `productUnavailable`, `purchaseNotAllowed` |
| `restore` | `Transaction.currentEntitlements`, without family-shared ones |
| `manage` | `AppStore.showManageSubscriptions(in:)`, or `https://apps.apple.com/account/subscriptions` |

So on iOS, the paywall names App Store product identifiers with no base plan, for example `plan_option(product_id: "premium.monthly")`.

## Testing your paywall

You can try the whole flow in the simulator without App Store Connect:

1. In Xcode, *File › New › File… › StoreKit Configuration File*, and add your subscriptions with the same product identifiers as the paywall.
2. Select it in your scheme: *Edit Scheme… › Run › Options › StoreKit Configuration*.
3. Run the app, open the paywall, buy, then manage transactions from *Debug › StoreKit › Manage Transactions*.

Signed transactions from a StoreKit configuration file are signed by Xcode, not by Apple: your server rejects them, as it should. Use a sandbox account on a device to test verification end to end.

## Development

```sh
swift test
xcodebuild -project Example/TillbellExample.xcodeproj -scheme TillbellExample -destination 'generic/platform=iOS Simulator' build-for-testing
```

`swift test` runs the unit tests on the Mac: the StoreKit logic is tested against a fake StoreKit client, and every reply is checked against the contract's JSON Schemas, so the tests need neither a device nor the App Store. `xcodebuild` builds the example app for iOS, and with it the package and the bridge component, which needs iOS. CI runs these two commands on every pull request, and skips documentation-only changes.

[`Example/`](Example) is the smallest app that registers the component. Its tests run the real StoreKit 2 code against StoreKitTest and [`Tillbell.storekit`](Example/Tillbell.storekit): prices, a purchase and its signed transaction (with every field tillbell-rails reads), restore, `already_owned`, an upgrade, a downgrade and Ask to Buy. CI compiles them. StoreKitTest needs a host app and a simulator, so they run apart from `swift test`:

```sh
cd Example
xcodebuild test -scheme TillbellExample -destination 'platform=iOS Simulator,name=<an iOS 27 simulator>'
```

The project is generated by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `Example/project.yml` (`cd Example && xcodegen`); the generated project is committed so the example opens in Xcode without it. On the iOS 26.5 simulator runtime, StoreKitTest returned no products in our runs; use an iOS 27 simulator.

The bridge contract is copied into [`Tests/TillbellTests/Resources/contract`](Tests/TillbellTests/Resources/contract). To update it, copy the `contract/` directory of a newer tillbell-rails release there and record the version in its README.

## The Tillbell family

| Repository | Role |
|---|---|
| [tillbell-rails](https://github.com/pmakerhq/tillbell-rails) | Rails engine: paywall, purchase verification, subscriptions on top of Pay |
| [tillbell-android](https://github.com/pmakerhq/tillbell-android) | Hotwire Native bridge component for Google Play Billing |
| **tillbell-ios** | Hotwire Native bridge component for StoreKit 2 (this repository) |

## Contributing

Issues and pull requests are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md) first. To report a security problem, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## License

Tillbell is released under the [MIT license](LICENSE).
