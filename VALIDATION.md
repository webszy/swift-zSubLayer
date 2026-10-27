# Validation record — 2026-10-27

This record distinguishes compilation, executed simulator tests and environment
failures. It does not assert production readiness or App Store Sandbox coverage.
The supplied directory has no Git repository metadata; no commit or push was made.

**Final result: 44 test functions passed, 0 failed, 0 skipped**, on iPhone 18 Pro
Max / iOS 27.0. This comprises 33 Swift Testing unit functions, 10 Swift Testing
StoreKit integration functions, and 1 native cancellation UI test. Including
parameterized cases, the device summary reports 56 successful executions.

## Toolchain and dependency

- Xcode 27.0, build `27A266a`, at `/Applications/Xcode.app`.
- Discovered iOS 27.0 and iOS 26.5 simulator runtimes. Initial tests used
  iPhone 18 Pro (`2F8B3EDF-BF5E-42B4-BB2D-22F844BC1D6B`).
- StoreKitTheKit remained pinned to **1.5.4**,
  `a77bf8360680241652461f0ac4cb09fdca8c3a48`. Its checkout was reviewed and
  remained unmodified. `Package.swift` and root `Package.resolved` are unchanged.

## Commands actually attempted

| Check | Result |
| --- | --- |
| `swift package resolve` | Passed after using writable cache/config/security paths and `--disable-sandbox` for SwiftPM's prohibited nested sandbox. |
| `swift package dump-package` | Passed with the same environment. |
| iOS 15 Simulator library compilation with SwiftPM | Passed, including Swift 6 checking of the changed library and fixed upstream dependency. |
| iOS 17 Simulator unit-test compilation with SwiftPM | Passed. |
| `xcodebuild` iOS Simulator build and test | Executed, but blocked in this terminal environment by manifest sandbox/cache permission and CoreSimulator XPC failures. These command-line attempts are **not passes**. |
| Xcode Product → Test | Actually compiled the library, Demo and test bundles and executed Swift Testing / StoreKitTest on the simulator. Results below. |
| Plain `swift test` of the cross-compiled iOS test bundle | Failed: SwiftPM tried to load an iOS Simulator bundle in its macOS test helper. Use the hosted Xcode test target instead. |
| Project plist and test-script shell syntax | Passed. These are static checks only. |

Successful library compilation command:

```bash
env CLANG_MODULE_CACHE_PATH=/tmp/zsublayer-module-cache \
    SWIFTPM_MODULECACHE_OVERRIDE=/tmp/zsublayer-module-cache \
swift build --disable-sandbox \
    --cache-path /tmp/zsublayer-spm-cache \
    --config-path /tmp/zsublayer-spm-config \
    --security-path /tmp/zsublayer-spm-security \
    --triple arm64-apple-ios15.0-simulator \
    --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk
```

The equivalent hosted CLI build/test commands are in `scripts/test-ios.sh`.
They require an environment with normal Xcode/CoreSimulator permissions. No
privilege escalation, machine security-setting change or real payment was used.

## Executed test rounds

1. **First iOS 27 run:** 35 test functions, 31 passed, 4 failed, 0 skipped.
   All 26 unit functions passed. Native failures included the first-purchase
   timeout, expiry, retry/grace and injected cancellation (parameterized runs
   are aggregated by test function in this summary).
2. **After fixture/concurrency corrections, iOS 27:** 37 test functions,
   **36 passed, 1 failed, 0 skipped**. All 28 unit functions passed. Purchase,
   external purchase/renewal, automatic expiry, refund, pending approval,
   restore errors, billing retry, verified grace and metadata recovery passed.
   Only `cancelledAndFailedPurchasesRemainLocked()` failed.
3. **iOS 26.5 cross-check:** The test host built and launched, but its local
   StoreKit service rejected configuration/overrides with
   `SKInternalErrorDomain Code=3`, returned `.notEntitled`, and reported a
   Sandbox environment. Native results from that environment are failures,
   not entitlement-logic passes. No account login was attempted.
4. **After splitting failure paths and adding UI coverage:** All unit and
   StoreKit integration functions passed. The first UI test failed because
   the confirmation sheet belonged to a system UI process; the query was
   extended to the system purchase UI. A separate earlier round exposed delayed
   StoreKit history clearing between tests. Setup now waits for that clearing;
   immediate purchase and event assertions remain unchanged.
5. **iOS 27 run, 16:28–16:29:** **39 passed, 0 failed, 0 skipped**.
   Actual confirmation-sheet cancellation passed in 28.869 seconds and asserted
   `.cancelled`, no premium access and no local transaction. The result bundle
   is preserved as `.build/validation/2026-10-27/before-family-fix.xcresult`.
6. **Final iOS 27 run, 16:37–16:38:** **44 passed, 0 failed, 0 skipped**,
   with 56 successful device executions including parameterized cases. Independent
   review identified the same-Product-ID personal/family lineage issue after the
   earlier passing run. The adapter now preserves all verified lineages, merges
   signed invalidation only by transaction ID, and retains finite grace fallback
   per transaction. Five new regression functions cover eight parameterized cases.
   All existing unit, StoreKit integration and actual cancellation UI tests passed
   again. The final bundle is `.build/validation/2026-10-27/final.xcresult`, with
   `final-summary.json` and `final-tests.json` beside it. The iOS 15 deployment
   compilation also passed after this fix.

The cancellation and network purchase failure checks were subsequently split
into separate tests, so one failure cannot prevent the other path from running.
Native UI automation was added to test actual cancellation independently of
Apple's injected-error transport.

## Diagnosed cancellation injection mismatch

The test requests Apple's documented error-injection API:

```swift
try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
```

In the tested iOS 27 service, this produces `ASDServerErrorDomain Code=907`,
then StoreKit `.unknown`, then the SDK's `.purchaseFailed("Unable to Complete
Request")`, instead of `.cancelled`. There is no verified public cancellation
signal in that returned error. The wrapper deliberately does not classify
unknown errors as cancellation or hard-code a private error code.

This is an observed test-service mismatch; attribution to an Apple implementation
bug remains an inference. The fixture now checks this API's observable safety
contract: cancellation or a propagated purchase failure, with no granted access.
That does not count as proof of genuine cancellation. The new XCUITest separately
requires `.cancelled` after tapping the actual confirmation-sheet Cancel control,
and **passed** in the final run. No test is disabled, skipped or marked as an
expected failure. The original injected-cancellation failure is preserved in the
earlier result bundles rather than hidden. See `TESTING.md` for the manual path.

## Artifacts and limits

Logs, copied result bundles and parsed summaries are under
`.build/validation/2026-10-27/`. The Xcode originals are under
`~/Library/Developer/Xcode/DerivedData/DemoApp-dplcyjjbozehxvctwqaiyqsprdwn/Logs/Test/`.

The Demo was also launched on iPhone 18 Pro Max (iOS 27). Its local UI displayed
`isPremium: false`, resolved inactive status, monthly `$2.99`, yearly `$24.99`,
and Purchase / Restore controls without an Apple ID login. Direct computer-use
clicking was unreliable across Device Hub windows, so cancellation was instead
verified by the passing native XCUITest.

No physical iOS 15 device/runtime was available, so iOS 15 evidence is compilation
against the deployment target, not runtime execution. No real account, App Store
Sandbox payment, background process delivery, reinstall or production transaction
is claimed verified. Manual relaunch/offline steps remain in `TESTING.md`.
