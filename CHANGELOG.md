# Changelog

All notable changes to ZSubLayer will be documented here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Public zero-boilerplate `SubscriptionManager.shared.configure(productIDs:)` integration.
- Single-ID `purchase()`, multi-ID `purchase(_:)`, and `restore()`.
- StoreKitTheKit 1.5.4 real purchase / entitlement / sync integration.
- `products`, `isPremium`, `activeEntitlements`, `isReady`, `lastError` published state.
- Automatic startup, foreground synchronization, live entitlement observation.
- Native App Store subscription-management UI and product display metadata.
- Swift Package, tests, CI, MIT license and integration guide.

### Pending verification
- iOS Simulator compile and unit tests.
- StoreKit Configuration and App Store Sandbox purchase, refund, grace period and offline tests.

<!-- Add release links after publishing a GitHub repository. -->
