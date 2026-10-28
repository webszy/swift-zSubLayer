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

The script selects an installed Xcode and an available iPhone simulator from
CoreSimulator's device/runtime inventory. Its runtime must be iOS 17+ and no newer
than the selected Xcode's Simulator SDK major/minor version. It prefers the
newest compatible runtime, then an already booted device, and waits for boot.
It then asks Xcode to resolve build settings for that exact destination with
`-sdk iphonesimulator` and a 120-second destination timeout before building.
Xcode's initial `-showdestinations` output is saved for diagnostics; a fresh
runner may list only generic placeholders before Simulator boot, so that text
is not used to filter candidate devices. An unresolvable explicit destination
still fails the script before build/test; it never selects a fallback device.
It runs `swift package resolve`, `swift package dump-package`, an explicit
`xcodebuild -resolvePackageDependencies`, `xcodebuild build` and `xcodebuild test`.
Both resolvers use committed versions; Xcode populates a separate fresh package
directory shared by resolution, build and test. A failed command makes the script
fail. It never filters failing tests or marks them as expected failures.
Artifacts go to `.build/validation/<timestamp>-<pid>/`, printed even on failure.

To select a specific installed toolchain or simulator, set `DEVELOPER_DIR` or
`ZSUBLAYER_SIMULATOR_ID`; explicit simulator IDs undergo the same compatibility
checks. `ZSUBLAYER_EXPECTED_XCODE_VERSION=27.0` rejects another Xcode version.
In an environment that prohibits nested SwiftPM
sandboxing, `ZSUBLAYER_DISABLE_SPM_SANDBOX=1` disables SwiftPM's nested sandbox
only; OS/tool permission restrictions still apply.

### GitHub Actions

CI uses `xcode-27` and `/Applications/Xcode_27.app/Contents/Developer`, with an
exact Xcode 27.0 version check. The workflow prints Xcode, Swift, Simulator SDK,
installed runtimes and available devices. The shared `DemoApp` scheme runs
`ZSubLayerUnitTests`, `StoreKitIntegrationTests` and `DemoAppUITests` without
parallel testing, filtering or retries that could hide a failing test.

After committing and pushing the reviewed changes, open Actions → Swift Package
CI and inspect the run for that commit (or use Run workflow). Require successful
dependency resolution, `BUILD SUCCEEDED` and `TEST SUCCEEDED`, with all three
test targets present and passing in `Tests.xcresult`. Only a fully passing
GitHub Actions run validates the CI repair.

The `Upload CI diagnostics` step runs even after failures. Download
`zsublayer-ci-diagnostics` from the run's Artifacts section within five days.
It includes `toolchain.log`, `resolve.log`, `build.log`, `test.log`, simulator
selection/boot diagnostics, destination inventory and the complete
`Tests.xcresult` directory when produced. Open that directory with Xcode to
inspect test failures and UI attachments. Phases not reached have an explicit
"Phase not started" log; `Tests.xcresult` exists only once testing starts.

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

### 2026-10-28 regression checks — added, not executed

The wrapper fixes retain the original remote StoreKitTheKit 1.5.4 dependency.
No build or test run was performed for these changes. The earlier results in
`VALIDATION.md` do not validate this revision.

Run the existing DemoApp test scheme (Command-U) to include the new tests in
`SubscriptionManagerTests.swift`:

1. Hold a restore open, queue a purchase, cancel it, then release the restore.
   Expect `CancellationError`, zero purchase calls and no `lastError`; a later
   purchase must still work.
2. Cancel while missing-product metadata is loading. Expect no store purchase.
   With two callers sharing the same purchase, cancelling only one must preserve
   the other caller's single purchase. Cancellation after store handoff must
   still return the final payment result and reconcile access.
3. Advance the test clock across active and grace deadlines without delivering
   the timer. `hasActiveEntitlement(for:)` must immediately return false for the
   expired product while another valid product remains accessible. The old
   published snapshot intentionally remains compatible and may still be stale.
4. The injected vendor purchase first returns `productNotFound`, then succeeds
   after synchronization. Expect exactly one sync and two attempts. If the
   product remains missing, expect a surfaced error after the second attempt.
   Success, cancellation, pending approval and verification failure must not retry.

These vendor-call injections verify wrapper control flow, not live App Store
cache behavior. Manually check a partial product catalog that later becomes
available, and confirm the newly displayed product can be purchased. Concurrent
upstream background synchronization may still cause a transient unavailable
error because the unmodified vendor API does not join an in-flight sync.

The upstream listener's finishing of unrelated products is deliberately **not
fixed**, per the decision to retain the original remote dependency. No test or
release claim should imply safe isolation from another consumable-delivery flow.

### Earlier execution evidence

Results from this session are recorded in `VALIDATION.md`, including failed
attempts and environment limitations. No real App Store Sandbox or production
purchase validation is claimed.

References: [Apple SKTestSession](https://developer.apple.com/documentation/storekittest/sktestsession),
[currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements),
[subscription renewal states](https://developer.apple.com/documentation/storekit/product/subscriptioninfo/renewalstate).
