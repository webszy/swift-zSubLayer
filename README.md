# ZSubLayer

> Configure IAP product IDs once. Buy, restore and check premium access anywhere.

[![Swift](https://img.shields.io/badge/Swift-6.1%2B-orange.svg)](https://swift.org)
[![iOS](https://img.shields.io/badge/iOS-15%2B-blue.svg)](https://developer.apple.com/ios/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

ZSubLayer is a small, **subscription-only**, native iOS Swift Package built on top of [StoreKitTheKit](https://github.com/nicolaischneider/StoreKitTheKit). It hides StoreKit transactions, product registration, entitlement monitoring, restoration and foreground refresh behind a single observable singleton.

**Development status:** The library and Demo build in Swift 6 for iOS Simulator. Swift Testing and local StoreKitTest coverage are included. See [TESTING.md](TESTING.md) for actual results, remaining failures, and reproducible commands; local tests do not establish App Store Sandbox or production readiness.

## Requirements

- iOS 15+
- Swift Tools 6.1+ / Xcode with compatible Swift toolchain
- StoreKitTheKit 1.5.4 (exact SPM dependency)
- App Store Connect subscription products configured for the host app

## Installation

In Xcode select **File → Add Package Dependencies** and enter `https://github.com/webszy/swift-zSubLayer.git`, then select the `main` branch.

Or add to the consuming package's manifest:

```swift
.package(url: "https://github.com/webszy/swift-zSubLayer.git", branch: "main")
```

Use the `main` branch until a versioned release is published.

## Minimal integration

**1. Configure once** near app startup. ZSubLayer begins initialization automatically and listens for later entitlement changes.

```swift
import ZSubLayer

SubscriptionManager.shared.configure(
    productIDs: ["com.example.premium.monthly"]
)
```

**2. Purchase** from your paywall button:

```swift
// Exactly one configured Product ID:
let result = try await SubscriptionManager.shared.purchase()

// Multiple configured products: choose explicitly.
let annual = try await SubscriptionManager.shared.purchase("com.example.premium.yearly")
```

**3. Restore purchases** (provide a visible restore action in your app):

```swift
try await SubscriptionManager.shared.restore()
```

**4. Check premium access** anywhere on the main actor:

```swift
if SubscriptionManager.shared.isPremium {
    // Unlock paid features.
}
```

For SwiftUI observation and reliable startup behavior:

```swift
import SwiftUI
import ZSubLayer

struct PremiumScreen: View {
    @ObservedObject private var subscriptions = SubscriptionManager.shared

    var body: some View {
        VStack {
            if !subscriptions.isReady {
                ProgressView("Checking subscription…")
            } else if subscriptions.isPremium {
                Text("Premium unlocked")
            } else {
                Button("Subscribe") {
                    Task {
                        do {
                            _ = try await subscriptions.purchase()
                        } catch {
                            // Show an alert/toast using your app's UI.
                            print(error.localizedDescription)
                        }
                    }
                }
            }
            Button("Restore Purchases") {
                Task {
                    do { try await subscriptions.restore() }
                    catch { print(error.localizedDescription) }
                }
            }
        }
    }
}
```

A cancelled purchase returns `.cancelled`; a family/Ask-to-Buy approval in progress returns `.pending`. They do not throw. Real errors throw and are also published as `lastError`.

## Public API

| API | Behavior |
| --- | --- |
| `configure(productIDs:)` | Register auto-renewable subscription IDs; start automatically |
| `purchase()` | Purchase the only configured subscription |
| `purchase(_:)` | Purchase a specifically configured ID |
| `restore()` | Prompt App Store sync; errors propagate to the caller |
| `refresh()` | Re-sync purchases and reload price metadata |
| `loadProducts()` | Reload App Store product display information |
| `manageSubscriptions()` | Open Apple's subscription management UI |
| `isPremium` | True when a configured subscription grants access |
| `activeEntitlements` | Set of currently accessible configured product IDs |
| `subscriptionStatus` | Billing/entitlement lifecycle summary |
| `isReady`, `isLoading`, `lastError` | Observable UI status |
| `products` | Display name, description, localized price and period |

Do not interpret `isPremium == false` as definitive while `isReady == false`. For more advanced offerings, use `activeEntitlements.contains(productID)` instead of assuming a single membership tier.

## Notes and limitations

- ZSubLayer is **only** for auto-renewable subscriptions at this stage; consumables, non-consumables and non-renewable subscriptions are out of scope.
- Product IDs are provided by the host app. You must create these products in App Store Connect and set up a StoreKit Configuration for local testing.
- Purchases use StoreKitTheKit 1.5.4. Access is independently reconciled from Apple's verified transactions and subscription status, including refunds, upgrades, grace and billing retry. Unverified transactions and vendor ownership/cache flags do not grant access.
- Offline access is bounded by the verified transaction expiry or verified grace deadline. It never extends just because connectivity is lost. A refund made while completely offline can only be learned when StoreKit delivers it; this client-only SDK is not server-side authorization.
- The singleton starts once per process. Repeating the same set of IDs (in any order) is a no-op; a different set is rejected through `lastError`. First-configuration ordering controls product display order.
- Initialization is shared by immediate purchases and concurrent callers. Same-product purchases share one in-flight result; different purchases, restores and refreshes are serialized. Once a payment starts, cancelling a Swift task does not cancel Apple's payment UI or roll back a transaction.
- The library **does not create a paywall UI**, display error alerts, or manage the app's internal premium-feature policy.
- `restore()` uses `AppStore.sync()` directly because the upstream implementation absorbs sync errors; UI code can then display real restore failures.
- `refresh()` and `loadProducts()` propagate product-loading errors and publish `lastError`, while retaining previously loaded prices. Startup still tolerates unavailable metadata so signed offline entitlements remain readable.
- Multi-product status is summarized for convenience; use `activeEntitlements` to inspect exactly which products are active. Product status is not a substitute for account-level backend entitlements.
- Android or server-to-server verification are not included.

## Architecture

```text
App UI (SwiftUI or UIKit)
    └─ SubscriptionManager.shared
         ├─ published isReady / isPremium / products / status
         └─ StoreKitAdapter (internal)
              ├─ StoreKitTheKit 1.5.4 (registration and purchasing)
              └─ Apple StoreKit 2 (verified access, automatic updates, metadata, restore)
```

## Validation (required before a release)

```bash
bash scripts/test-ios.sh
```

The script discovers Xcode and an iOS 17+ simulator, resolves the exact dependency, validates the manifest, then builds and tests the independent Demo project. The library still supports iOS 15.

Open `Examples/DemoApp/DemoApp.xcodeproj`, select the `DemoApp` scheme, and run or test it. Its bundled `Subscriptions.storekit` provides monthly and annual subscriptions locally: **no Apple ID, Sandbox account, App Store Connect setup or real payment is needed for this Demo**. Demo and StoreKitTest sources are outside the library target. See [TESTING.md](TESTING.md) for manual cancellation, relaunch and offline steps.

## License

MIT. See [LICENSE](LICENSE). StoreKitTheKit retains its own license.
