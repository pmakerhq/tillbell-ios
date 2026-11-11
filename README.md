# Tillbell for iOS

A [Hotwire Native](https://native.hotwired.dev) bridge component that runs the StoreKit 2 purchase flow for subscriptions sold from a Rails paywall.

This is the iOS half of Tillbell. The server half is [tillbell-rails](https://github.com/pmakerhq/tillbell-rails); the Android half is [tillbell-android](https://github.com/pmakerhq/tillbell-android).

> **Status: design phase.** Nothing is implemented yet and nothing here is ready to use. This README describes the goal and the planned shape of the project. Everything below is subject to change. App Store support is planned after Google Play support in tillbell-rails, so this repository will stay quiet until then.

## What it will do

Your paywall is a normal server-rendered Rails page. When the user taps "Subscribe", the page asks this component to:

1. look up the localized price of the products shown on the paywall, so the page can display it;
2. start the StoreKit 2 purchase for the selected product, tagging it with the purchase-intent UUID created by Rails (`appAccountToken`), so the store event can be tied back to your customer;
3. send the resulting transaction to your Rails app, which verifies it with Apple and unlocks the subscription;
4. finish transactions correctly, listen for transaction updates, and restore purchases from the user's current entitlements.

All business logic (who is subscribed, until when, in which state) stays in Rails. This component only talks to StoreKit and to the bridge.

## Planned requirements

To be confirmed when work starts: a recent Hotwire Native iOS release and the iOS version that StoreKit 2 requires.

## Planned installation

Distributed as a Swift package, with the component registered on the Hotwire bridge like any other. The exact instructions will be documented at the first release.

## License

Tillbell is released under the [MIT license](LICENSE).
