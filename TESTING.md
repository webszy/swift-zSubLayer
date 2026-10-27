# Local validation

The local Demo uses `Examples/DemoApp/Subscriptions.storekit`. It contains
`com.example.zsublayer.monthly` and `com.example.zsublayer.yearly`, in one
subscription group. The shared Scheme loads the file; automated tests install
an `SKTestSession` before constructing the SDK singleton. No Apple ID,
Sandbox account, App Store Connect connection or real payment is required.

The library remains an independent iOS 15 Swift Package. The separate test host
targets require iOS 17 to exercise StoreKit error injection and Swift Testing.
No test-only framework is imported by the library.

## Reproduce

From the package directory:

```bash
bash scripts/test-ios.sh
```

The script selects an installed Xcode and available iPhone simulator, preferring
an already booted device. It runs `swift package resolve`,
`swift package dump-package`, `xcodebuild build` and `xcodebuild test`. A failed
command makes the script fail. It never filters failing tests or marks them as
expected failures. Artifacts go to `.build/validation/<timestamp>/`.

To select a specific installed toolchain or simulator, set `DEVELOPER_DIR` or
`ZSUBLAYER_SIMULATOR_ID`. In an environment that prohibits nested SwiftPM
sandboxing, `ZSUBLAYER_DISABLE_SPM_SANDBOX=1` disables SwiftPM's nested sandbox
only; OS/tool permission restrictions still apply.

The equivalent Xcode workflow is:

1. Open `Examples/DemoApp/DemoApp.xcodeproj`.
2. Select Scheme `DemoApp` and an installed iOS 17+ simulator.
3. Use Product → Test (Command-U). The package's unit-test sources, StoreKit
   integration suite and native cancellation UI test are included. Don't enable parallel execution
   for the StoreKit integration target, which shares a process-wide store.
4. Use Product → Run (Command-R) to interact with the local paywall.

## Automated coverage

| Area | Tests |
| --- | --- |
| Configuration | All unconfigured entry points, empty IDs, duplicate IDs, reordered identical sets, rejected replacement, shared startup |
| Purchase | Single/multiple IDs, unavailable/unknown IDs, cancelled/pending/success/failure, unverified failure, no invented access on success without an entitlement |
| Restore | Successful reconciliation, propagated failures, removal of previous access |
| Concurrency | Immediate purchase during startup, duplicate purchase coalescing, serialized purchase/restore/refresh/metadata, updates during suspended refresh and metadata failure |
| Entitlements | Expiry boundaries, finite offline deadlines, refund/revocation, grace, billing retry, multiple IDs, ignoring unrelated products |
| Shared subscription sources | The same Product ID with personal/family lineages, offline fallback, same-lineage replacement, signed revoke/upgrade conflicts and grace cache bound to a transaction |
| Lifecycle | MainActor publication, foreground refresh, restart state, offline metadata startup and recovery, preservation of prices on network error |
| Local StoreKit | Native purchase and prices, external purchase, renewal with unchanged Product ID, automatic expiry, refund, pending approval, restore errors, retry/grace, product-service failure and recovery |
| Native UI | Actual local confirmation-sheet cancellation, separate from StoreKit error-injection behavior |

Fakes are internal to the tests. StoreKit integration tests use the real adapter,
vendor SDK and Apple's local StoreKit service. They assert immediate premium
state after a successful SDK purchase; they don't use a polling refresh to hide
that race. Polling in the suite only waits for external StoreKit event delivery
and always has a deadline.

The UI automation uses XCTest/XCUITest, which is required to control iOS system
purchase UI; unit and StoreKit integration tests use Swift Testing. An injected
`.userCancelled` can arrive as `.unknown` from the tested local StoreKit service.
That injection check accepts cancellation or a propagated `purchaseFailed` error,
and always requires no access. The separate UI test requires the actual
`.cancelled` outcome after tapping the confirmation sheet's Cancel control.

When testing accelerated subscription expiry or billing failures, set
`SKTestSession.timeRate` **before** purchasing. Changing it afterward does not
retroactively shorten an existing transaction's signed expiration date.

## Manual checks

1. **Fresh state and prices:** Run the Demo with its local configuration. Clear
   only the Demo's transactions through Xcode's StoreKit transaction manager.
   Relaunch; verify `isPremium: false`, a resolved status and localized prices.
2. **Purchase and real cancellation UI:** Tap Purchase and cancel Apple's local
   confirmation sheet. Expect `.cancelled`, no error and no premium access.
   Purchase again and confirm; premium should become true before the action
   reports completion. These are local simulated purchases.
3. **Restore:** Purchase, terminate and relaunch the Demo, then use Restore.
   Access should be present after startup and remain present after Restore.
   Enable an App Store Sync error in the configuration editor and restore again;
   verify an error is displayed without extending the previous entitlement.
4. **Renewal, expiry and refunds:** Use Xcode's StoreKit transaction manager to
   renew/refund the Demo subscription. Renewal must update the expiration with
   the same Product ID; refund must remove access. Accelerate time before a new
   purchase and turn off auto-renewal; wait for automatic expiry.
5. **Grace and billing retry:** Enable Billing Retry on Renewal, set accelerated
   time, and make a new purchase. Without grace, retry must not grant access.
   With grace enabled, access lasts only until the verified grace deadline.
6. **Offline and foreground:** With a valid subscription, disconnect networking
   or inject product/status network errors. Previously loaded prices may remain;
   access must stop at its signed deadline. Reconnect and foreground the app;
   metadata and verified access should refresh without a host-written listener.
7. **Relaunch while expired/revoked:** After expiry or refund, terminate and
   relaunch. Premium must stay false. Test both product choices; an expired
   product must not clear another valid entitlement.

## Execution evidence

Results from this session are recorded in `VALIDATION.md`, including failed
attempts and environment limitations. No real App Store Sandbox or production
purchase validation is claimed.

References: [Apple SKTestSession](https://developer.apple.com/documentation/storekittest/sktestsession),
[currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements),
[subscription renewal states](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalstate).
