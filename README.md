# ZSubLayer

> Configure IAP product IDs once. Buy, restore and check premium access anywhere.

[![Swift](https://img.shields.io/badge/Swift-6.1%2B-orange.svg)](https://swift.org)
[![iOS](https://img.shields.io/badge/iOS-15%2B-blue.svg)](https://developer.apple.com/ios/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

ZSubLayer is a small, **subscription-only**, native iOS Swift Package built on top of [StoreKitTheKit](https://github.com/nicolaischneider/StoreKitTheKit). It hides StoreKit transactions, product registration, entitlement monitoring, restoration and foreground refresh behind a single observable singleton.

**Development status (2026-10-28):** [VALIDATION.md](VALIDATION.md) records build and simulator test results for the earlier 2026-10-27 revision. The current local changes for product-cache recovery, queued-purchase cancellation and `hasActiveEntitlement(for:)` have **not been compiled or tested**. Their regression tests and manual checks are described in [TESTING.md](TESTING.md). Historical results do not validate these changes or establish App Store Sandbox or production readiness.

## Requirements

- iOS 15+
- Swift Tools 6.1+ / Xcode with compatible Swift toolchain
- StoreKitTheKit 1.5.4 (exact SPM dependency)
- App Store Connect subscription products configured for the host app

## Installation

In Xcode select **File → Add Package Dependencies** and enter `https://github.com/webszy/swift-zSubLayer.git`, then select the `main` branch and add the **ZSubLayer** product to your app target. StoreKitTheKit is resolved automatically; the host does not need to register products with it separately.

Or add to the consuming package's manifest:

```swift
.package(url: "https://github.com/webszy/swift-zSubLayer.git", branch: "main")
```

Also add the product to the consuming target's `dependencies`:

```swift
.product(name: "ZSubLayer", package: "swift-zSubLayer")
```

Use the `main` branch until a versioned release is published. **Local revision note (2026-10-28):** the wrapper fixes and new `hasActiveEntitlement(for:)` API described here are currently uncommitted local changes. Installing the published repository does not include these local changes. To evaluate this revision, add this checkout as a local package in Xcode instead of adding the remote package; use only one copy of ZSubLayer.

## Minimal integration

All `SubscriptionManager` APIs and properties are isolated to `@MainActor`. Use them from main-actor UI code, or explicitly hop to `MainActor` from background work. Replace the example product IDs with your app's auto-renewable subscription IDs.

**1. Configure once at startup.** ZSubLayer starts asynchronously and listens for later entitlement changes automatically. Choose the entry point matching your app; do not add a second app entry point to an existing project.

SwiftUI — place configuration in your existing `App.init`:

```swift
import SwiftUI
import ZSubLayer

@main
@MainActor
struct MyApp: App {
    init() {
        SubscriptionManager.shared.configure(
            productIDs: ["com.example.premium.monthly"]
        )
    }

    var body: some Scene {
        WindowGroup { PremiumScreen() } // Defined below.
    }
}
```

UIKit — add configuration to your existing app delegate:

```swift
import UIKit
import ZSubLayer

@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        SubscriptionManager.shared.configure(
            productIDs: ["com.example.premium.monthly"]
        )
        return true
    }
}
```

Configuration returns before startup completes. Observe `isReady` for UI, or call `try await SubscriptionManager.shared.start()` from an async context to wait. `isReady` means initial reconciliation completed; it does not guarantee that product metadata loaded successfully. Purchase and restore already wait for startup internally.

**2. Purchase** from your paywall button:

```swift
// In an async main-actor context, with the single monthly ID configured above:
let result = try await SubscriptionManager.shared.purchase()
```

For multiple products, **replace** the startup configuration above with the complete set before the first configuration call:

```swift
SubscriptionManager.shared.configure(productIDs: [
    "com.example.premium.monthly",
    "com.example.premium.yearly"
])
```

Then purchase an explicitly selected configured ID from your async button action:

```swift
let annual = try await SubscriptionManager.shared.purchase("com.example.premium.yearly")
```

These are alternative configurations, not sequential steps. Calling `purchase()` with multiple configured IDs throws `multipleProductsRequireID`; purchasing an unconfigured ID throws `invalidProductID`. A later `configure` call cannot replace the initial set.

**3. Restore purchases** (provide a visible restore action in your app):

```swift
try await SubscriptionManager.shared.restore()
```

**4. Check premium access** anywhere on the main actor:

```swift
let subscriptions = SubscriptionManager.shared
if subscriptions.isReady && subscriptions.isPremium {
    // Unlock paid features.
}

// For a specific product/tier, check its deadline at the time of use:
if subscriptions.isReady && subscriptions.hasActiveEntitlement(for: "com.example.premium.monthly") {
    // Unlock features associated with this product.
}
```

For SwiftUI observation and reliable startup behavior (using the single-product configuration above):

```swift
import SwiftUI
import ZSubLayer

@MainActor
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
                        } catch is CancellationError {
                            // This queued request was cancelled before store handoff.
                        } catch {
                            // Show an alert/toast using your app's UI.
                            print(error.localizedDescription)
                        }
                    }
                }
                .disabled(subscriptions.isLoading)
            }
            Button("Restore Purchases") {
                Task {
                    do { try await subscriptions.restore() }
                    catch { print(error.localizedDescription) }
                }
            }
            .disabled(subscriptions.isLoading)
        }
    }
}
```

Cancelling Apple's purchase sheet returns `.cancelled`; awaiting approval such as Ask to Buy returns `.pending`. Neither grants access or throws an error. Cancelling a Swift task before store handoff can instead throw `CancellationError`, which is not published as `lastError`. Store/product failures throw and are published as `lastError`. A `.purchased` result alone is not authorization: use the manager's verified access checks.

For UIKit, retain Combine subscriptions in the view controller. Observe published snapshots to update UI, then use the current access checks when authorizing a paid action. There is no `$isPremium` publisher because `isPremium` is a computed property:

```swift
import UIKit
import Combine
import ZSubLayer

@MainActor
final class PremiumViewController: UIViewController {
    private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()
        let subscriptions = SubscriptionManager.shared
        subscriptions.$activeEntitlements
            .combineLatest(subscriptions.$isReady)
            .sink { [weak self] _, _ in
                // Published properties emit before assignment; read after the actor hop.
                Task { @MainActor [weak self] in self?.renderMembership() }
            }
            .store(in: &cancellables)
        renderMembership()
    }

    private func renderMembership() {
        let subscriptions = SubscriptionManager.shared
        title = !subscriptions.isReady ? "Checking subscription…"
            : (subscriptions.isPremium ? "Premium" : "Subscribe")
    }
}
```

The SDK owns transaction monitoring and foreground refresh. The host does not need an additional transaction listener for these subscriptions.

## Public API

| API | Behavior |
| --- | --- |
| `configure(productIDs:)` | Register auto-renewable subscription IDs; start automatically |
| `start()` | Await shared initialization; normally started automatically by configuration |
| `purchase()` | Purchase the only configured subscription |
| `purchase(_:)` | Purchase a specifically configured ID |
| `restore()` | Prompt App Store sync; errors propagate to the caller |
| `refresh()` | Re-read verified entitlements and reload product metadata; does not call `AppStore.sync()` |
| `loadProducts()` | Reload App Store product display information |
| `manageSubscriptions()` | Open Apple's subscription management UI |
| `isPremium` | True when a configured subscription grants access |
| `hasActiveEntitlement(for:)` | Check one product against its verified deadline at the time of use |
| `activeEntitlements` | Last published set of accessible product IDs, for UI observation |
| `subscriptionStatus` | Billing/entitlement lifecycle summary |
| `isReady`, `isLoading`, `lastError` | Observable UI status |
| `products` | Display name, description, localized price and period |

Do not interpret `isPremium == false` as definitive while `isReady == false`. For more advanced offerings, use `hasActiveEntitlement(for: productID)` instead of assuming a single membership tier. Both access checks evaluate the verified deadline immediately. `activeEntitlements` and `subscriptionStatus` are published snapshots for UI observation and can lag while the app is suspended; do not use a cached snapshot to authorize a paid action.

## Notes and limitations

- ZSubLayer is **only** for auto-renewable subscriptions at this stage; consumables, non-consumables and non-renewable subscriptions are out of scope.
- Product IDs are provided by the host app. You must create these products in App Store Connect and set up a StoreKit Configuration for local testing.
- Purchases use StoreKitTheKit 1.5.4. Access is independently reconciled from Apple's verified transactions and subscription status, including refunds, upgrades, grace and billing retry. Unverified transactions and vendor ownership/cache flags do not grant access.
- Offline access is bounded by the verified transaction expiry or verified grace deadline. It never extends just because connectivity is lost. A refund made while completely offline can only be learned when StoreKit delivers it; this client-only SDK is not server-side authorization.
- The singleton starts once per process. Repeating the same set of IDs (in any order) is a no-op; a different set is rejected through `lastError`. First-configuration ordering controls product display order.
- Initialization is shared by immediate purchases and concurrent callers. Same-product purchases share one in-flight result; different purchases, restores and refreshes are serialized. If all callers cancel before the purchase is handed to the store adapter, queued work throws `CancellationError` without starting payment. One cancelled caller does not cancel another caller's shared purchase. After store handoff, all waiters still receive the store result; cancelling a Swift task does not cancel Apple's payment UI or roll back a transaction.
- If StoreKitTheKit's product cache is missing a displayed product, purchasing synchronizes that cache and retries once, only for the pre-payment `productNotFound` result. Cancellation, pending approval, successful payment and verification/payment errors are never retried. Upstream may skip a sync while its own background sync is running; a still-missing product remains a surfaced error, not an unbounded retry.
- StoreKitTheKit 1.5.4 is retained unchanged as a remote dependency. Its global listener finishes verified transaction updates even for unregistered products. This wrapper cannot prevent that behavior through the vendor's public API; do not rely on it being isolated from a separate consumable-delivery flow in the same host app.
- The library **does not create a paywall UI**, display error alerts, or manage the app's internal premium-feature policy.
- `restore()` uses `AppStore.sync()` directly because the upstream implementation absorbs sync errors; UI code can then display real restore failures.
- `refresh()` and `loadProducts()` propagate product-loading errors and publish `lastError`, while retaining previously loaded prices. Startup still tolerates unavailable metadata so signed offline entitlements remain readable.
- Multi-product status is summarized for convenience; use `hasActiveEntitlement(for:)` to authorize a specific product and `activeEntitlements` to observe the last published set. Product status is not a substitute for account-level backend entitlements.
- Android or server-to-server verification are not included.

## Architecture

```text
App UI (SwiftUI or UIKit)
    └─ SubscriptionManager.shared
         ├─ published isReady / isLoading / lastError / products / subscriptionStatus / activeEntitlements
         ├─ computed isPremium; immediate hasActiveEntitlement(for:) check
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
