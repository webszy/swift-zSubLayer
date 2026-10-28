# CI toolchain alignment — 2026-10-28

Status: **complete local CI script passed, 53/53 test functions; GitHub Actions
verification pending**.

Inspected the complete log and xcresult from
[run 40707505016](https://github.com/webszy/swift-zSubLayer/actions/runs/40707505016)
for commit `83dd4c61ab47831d515f85998adcb6baac8f737f`. The downloaded 46 MB
diagnostic ZIP matches GitHub's SHA-256 digest
`aee114fe5351e15993ca40a99563cd4a6467eca51d9371b584ec1bd6be7db99e`.

- Result: **52 passed, 1 failed, 0 skipped** test functions. The single failing
  function has two failed parameter cases: billing retry with and without grace.
- All 42 unit functions, first purchase, the other StoreKit integration cases
  and genuine native UI cancellation passed. The previous initialization and
  cancellation-control changes are now verified on GitHub Actions.
- Both renewal cases timed out after the 75-second bounded event wait. At the
  failure, both the wrapper and native StoreKit returned `expired` (native state
  raw value 2). This is evidence about the native test environment, not a reason
  to grant access from an expired entitlement or to relax the expected states.
- Offline daemon logs show renewal and synchronization delays. In the retry
  case, transaction 7's deadline was 14:46:40 UTC, while renewal processing began
  at 14:47:09. In the grace case, native status synchronization began at
  14:48:10 and completed at 14:48:48, after the recorded 14:48:27 deadline.
  A larger wait alone does not preserve an already elapsed state window.
- CI still used **Xcode 27.0 (`27A266a`) / SDK 27.0**. The passing local results
  used **Xcode 27.1 (`27A9275`) / SDK 27.1**. Those were different toolchains.

The workflow now explicitly selects Xcode 27.1 and keeps an exact 27.1 guard.
GitHub's [xcode-27 runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
lists that version at `/Applications/Xcode_27.1.app`, with SDK/runtime 27.1.
The complete existing CI script passed locally with that version guard, fresh
dependency/build directories and automatic compatible-runtime selection:

- Xcode 27.1 (`27A9275`), SDK 27.1, iPhone Duo / iOS 27.1 (`24A94425`).
- Both lockfile-constrained resolvers, package manifest validation, explicit
  Simulator boot/destination validation and DemoApp build passed.
- All **53 test functions passed**, including 42 unit functions, 10 integration
  functions and native cancellation UI. Including parameters: **68 successful
  device executions, 0 failed, 0 skipped, 0 expected failures**.
- Both billing retry/grace parameters passed together in 60.856 seconds; native
  UI cancellation passed in 17.244 seconds. The script exited 0.
- Workflow YAML parsing, exact toolchain guard and `git diff --check` passed.

SDK code, test cases, assertions, timeouts and the dependency pin are unchanged
in this follow-up. A new passing Actions run is required to establish whether
aligning the toolchain resolves the remaining failure; this record does not
attribute a specific unconfirmed defect to Apple.

Evidence from the failed run is under
`.build/validation/ci-run-40707505016/`, including `summary.json`, exported test
diagnostics and `storekit-system.log`. New script output is under
`.build/validation/ci-toolchain-27.1/`, including `local-summary.json`. The full
local result bundle is `.build/validation/20261028-230845-3260/Tests.xcresult`.

# StoreKit CI failure follow-up — 2026-10-28 (historical)

Status: **all 53 test functions pass locally; new GitHub Actions execution
still required**.
The SDK sources, public APIs, dependency pin and access assertions are unchanged.

## Evidence from the latest failed run

Inspected the job log, downloaded the 55 MB diagnostic artifact and exported
the complete xcresult diagnostics and UI attachments from
[run 40674183931](https://github.com/webszy/swift-zSubLayer/actions/runs/40674183931),
commit `c11b70fa917bd473945df11c5102610fae6a3c55`.

- Xcode 27.0 selected iPhone 17 / iOS 27.0, booted it, resolved the explicit
  destination and built DemoApp successfully. The destination-discovery repair
  worked. All 42 unit-test functions passed.
- The result bundle reports **50 passed, 3 failed, 0 skipped** test functions
  (**65 passed, 3 failed** device executions including parameters). The failures
  are the first SDK purchase, grace-period renewal, and native UI cancellation.
- The first purchase's StoreKit request `5093008D_SK2` started Sandbox
  authentication with no active account at 10:49:04 UTC. It remained blocked
  until the UI runner dismissed its Apple Account alert at 10:53:38 UTC, after
  the integration test's 120-second timeout and host restart. Other requests
  already used XcodeTest. This establishes a mixed test environment at startup,
  not an SDK purchase error or a missing-product failure.
- The UI screenshot **does show the local Xcode payment sheet**. SpringBoard's
  exported hierarchy contains `NavigationBar identifier: 'Xcode'` and its
  `Button identifier: 'dismiss', label: 'close'`. The old case-sensitive query
  accepted `Close`, not `close`, so it missed the real cancellation control.
  The earlier Apple Account alert was a leftover from the timed-out purchase;
  it does not mean that the UI test's purchase used the live App Store.
- Billing retry without grace passed; grace timed out. The test used
  `.oneRenewalEveryTwoSeconds`, whose grace window is also only two seconds.
  The daemon did not process renewal until 10:52:28, after the recorded next
  renewal deadline of 10:52:27. This supports a missed transient grace window;
  the old logs do not expose the signed grace payload, so they cannot prove
  that timing is the only cause.

Apple documents the [two-second grace window](https://developer.apple.com/documentation/storekittest/sktestsession/timerate-swift.enum/onerenewaleverytwoseconds)
and the [30-second alternative](https://developer.apple.com/documentation/storekittest/sktestsession/timerate-swift.enum/onerenewaleverythirtyseconds).
Their [test-session documentation](https://developer.apple.com/documentation/storekittest/sktestsession)
also requires serial execution because sessions share one environment.

## Corrections under validation

The Debug Demo test host installs and retains a local `SKTestSession` in app
initialization before any SDK startup. Test methods still reset their scenarios.
Unit/integration launches suppress dialogs. The UI runner owns a separate test
session with dialogs enabled; its standalone paywall app does not create one.
`ENABLE_TESTING_SEARCH_PATHS` is enabled only for the app's Debug configuration;
the StoreKitTest import and bootstrap are excluded from Release.

The UI query uses the observed `dismiss` identifier and case-insensitive
close/Cancel labels **inside the Xcode navigation bar**. A generic login-alert
Cancel cannot satisfy it. It still requires `.cancelled`, no premium access and
an empty local transaction history. Failure attachments include all three UI
process hierarchies.

The billing test now gives renewal and grace 30 seconds each, with a 75-second
bounded event wait. Access assertions and the future verified grace deadline
remain required. A timeout additionally reports manager and native StoreKit
renewal states, without refreshing the manager to manufacture a pass.

## Local validation

- Resolved the unchanged StoreKitTheKit 1.5.4 dependency using its committed lock.
- Initial Debug build failed to locate StoreKitTest from the app target. Adding
  Debug-only testing search paths corrected that build configuration.
- `build-for-testing`: **passed** for DemoApp and all three test targets with
  Swift 6 checking. Apple framework deprecation and unused AppIntents metadata
  warnings remain; there are no compilation errors.
- The first local run passed all 42 unit and 10 integration functions, including
  the first purchase in 0.219 seconds and both retry/grace parameters. The UI app
  then crashed because the initial bootstrap also ran in the standalone UI
  application. Its crash stack identifies `SKTestSession.bundleID` requiring
  XCTest configuration. Bootstrap is now limited to hosted XCTest launches;
  the UI runner alone creates its test session. That failed bundle is retained.
- Final full `xcodebuild test`: **53 passed, 0 failed, 0 skipped, 0 expected
  failures**, comprising all 42 unit functions, 10 integration functions and the
  native UI test. Including parameterized cases: **68 passed** device executions.
  The first purchase, both retry/grace cases, product-error recovery and native
  cancellation all passed. The UI test located the actual local sheet, dismissed
  it and verified `.cancelled`, no entitlement and no local transaction (16.037
  seconds). The first run's UI startup failure is not counted as a pass.
- Local toolchain is **Xcode 27.1 (`27A9275`), Simulator SDK 27.1**, not the
  runner's Xcode/SDK 27.0. Runtime testing targets an unused iPhone 17 / iOS 27.0
  (`7130543B-6610-45F6-B185-4DCDABBB144F`). Local success alone cannot validate
  the exact CI toolchain.
- `plutil -lint` for the project and `git diff --check`: passed.

Downloaded evidence is under `.build/validation/ci-run-40674183931/`, including
`storekit-system.log`, `test-diagnostics/`, `ui-attachments/` and the original
`Tests.xcresult`. New compilation/test logs, the failed `Tests.xcresult`, passing
`FinalTests.xcresult`, `final-summary.json` and `final-tests.json` are under
`.build/validation/storekit-ci-followup/`.

## CI acceptance

Run the unchanged workflow against this revision and require all **53** test
functions to pass on Xcode 27.0 / iOS 27.0, with no skips or expected failures.
In particular the first SDK purchase must complete without account login or
host restart, both retry/grace parameters must pass, and native sheet dismissal
must return `.cancelled`. The earlier failed run is preserved as evidence.

# CI destination discovery follow-up — 2026-10-28 (historical)

Status: **local regression checks passed; a new GitHub Actions run is still
required**. This follow-up has not been compiled, run on a Simulator, committed
or pushed locally. SDK sources, public APIs, StoreKit behavior and test assertions
are unchanged.

## Failure established from the actual runner

Inspected the complete job log and downloaded the diagnostic artifact from
[run 40671349268](https://github.com/webszy/swift-zSubLayer/actions/runs/40671349268),
commit `5f09b820a81b69e429d0b5ded8084b093fde463b`:

- Xcode 27.0 (`27A266a`), iOS Simulator SDK 27.0 and both package resolvers worked.
- `simulators.json` contains available iOS 27.0 iPhones, all shut down. iOS 27.1
  is also installed and must remain excluded when using SDK 27.0.
- The initial `-showdestinations` output lists only generic Simulator/device
  placeholders and My Mac. The previous script required each candidate UUID
  to appear in that output, so it rejected all available iPhones before boot.
  Xcode 27 uses the heading `Destinations compatible with` in this output;
  parsing the human-readable heading/list is unnecessary for device selection.
- The script exited 1 with `No compatible iOS 17+ iPhone simulator for SDK 27.0`.
  Neither Build nor Test ran. This failure provides no evidence of an SDK defect.
- Artifact upload succeeded. The diagnostic ZIP was actually downloaded and its
  eight files inspected, including resolve, build, test, destination and Simulator
  logs/inventory. No xcresult exists because testing never started. Result-bundle
  upload after a real test failure remains to be verified.

## Correction and local checks

Candidate selection now uses CoreSimulator's available device/runtime inventory
and the existing SDK version bounds, including for explicit UUID overrides.
`-showdestinations` is saved for diagnostics without filtering candidates.
After `simctl bootstatus -b` completes, Xcode must successfully resolve build
settings for that exact destination, with `-sdk iphonesimulator` and a 120-second
destination timeout. Failure still stops the script before Build/Test and is
saved in `destinations.log`; there is no fallback destination or skipped test.

- Replayed the downloaded `simulators.json` and `destinations.log` against the
  committed script using command fixtures: reproduced exit 1 and the same
  no-compatible-Simulator error.
- Replayed the same payloads against the corrected script: passed. The fixture
  requires boot to complete before destination validation, then requires Build
  and Test to use that same validated UUID and Simulator SDK.
- All **21/21 command-fixture checks passed**. They also cover legacy placeholder
  output, newer/unavailable/unknown/iPad overrides, wrong Xcode, dependency errors,
  boot errors, explicit destination rejection and Build/Test exit-code propagation.
  A destination rejection exits 65 before Build; test failure retains the full
  mock result-bundle attachment. These are script checks, not real Apple tests.
- `/bin/bash -n scripts/test-ios.sh` and `git diff --check`: passed.

Evidence is under `.build/validation/ci-followup-checks/`; the downloaded artifact
is under `.build/validation/ci-run-40671349268/`. The session's fixture harness is
`/tmp/zsublayer-ci-checks/check_ci.py`. No real compilation or Simulator execution
was performed after editing, following the repository instruction.

## Retest

Review and push this follow-up, then inspect the new Actions run. Require a
selected iOS 27.0 iPhone, completed boot and successful explicit destination
validation, followed by successful DemoApp Build and all three test targets.
If any phase fails, download `zsublayer-ci-diagnostics` and inspect the recorded
phase logs and result bundle when present. CI repair is unverified until the
actual run passes in full.

# Initial CI repair validation — 2026-10-28 (historical)

Status at initial local validation: **local CI configuration/script checks passed; repaired GitHub Actions
run not executed or verified**. No commit or push was made. The prior simulator
results below do not validate this revision.

## Failed CI evidence

Inspected the complete job log for
[run 40660474366](https://github.com/webszy/swift-zSubLayer/actions/runs/40660474366),
commit `3c7c7ad7d4c1fd2d16912ba320a77423b1482acb`:

- Runner: `macos-15-arm64`; Xcode 16.4 (`16F6`), Swift 6.1.2, iOS Simulator SDK
  18.5. The old selector chose iPhone 17 Pro / iOS 26.2. That runtime is newer
  than the selected toolchain's SDK, despite appearing in its destination list.
- StoreKitTheKit 1.5.4 resolved and DemoApp reported `BUILD SUCCEEDED`.
  The unit-test run reported 42 tests passed.
- StoreKit integration failed: both billing-retry/grace cases timed out;
  `metadataNetworkFailureRecoversWithoutLosingPaidAccess` failed its expected
  error and preserved-product assertions. The native cancellation UI test failed
  because the local confirmation did not appear. `xcodebuild test` exited 65.
- This establishes a toolchain/runtime mismatch and actual test failures; it
  does not prove that changing the runner fixes every failure or that SDK
  business logic is defective. Test assertions and SDK sources were not changed.

The existing uncommitted workflow already selected `xcode-27`, set the Xcode
path and added artifact upload. Those changes were retained and completed.
GitHub's [runner software inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
lists Xcode 27.0 (`27A266a`) at `/Applications/Xcode_27.app`, including iOS 27.0
SDK/runtime. The script additionally verifies the requested Xcode version.

## Local checks actually executed

- `/bin/bash -n scripts/test-ios.sh`: passed using macOS Bash 3.2.57.
- Workflow YAML parsing and checks of runner, exact version guard, unconditional
  upload and hidden-file inclusion: passed using Ruby's YAML parser.
- DemoApp project/scheme structural checks: passed. All three test targets are
  enabled, referenced test sources exist, integration/UI targets bundle
  `Subscriptions.storekit`, and both lockfiles match the pinned 1.5.4 revision.
- 18 isolated command-fixture checks: passed. They execute a copy of the shell
  script against fake `swift`, `xcodebuild` and `xcrun` commands in fresh temporary
  directories (including spaces in paths). Cases cover newer/older/mixed
  runtimes; explicit valid, unavailable, ineligible, iPad and unknown IDs;
  Xcode version mismatch; resolution, destination, boot, build and test errors.
  Build/test failure code 65 survives `tee` and the EXIT trap; unstarted phases
  are marked; a failing test retains a nested result-bundle attachment.
  These are script checks, **not executed SDK or Simulator tests**.
- `git diff --check`: passed.

Local fixture summary: `.build/validation/ci-repair-checks/script-checks.log`.
The harness is at `/tmp/zsublayer-ci-checks/check_ci.py` for this machine/session.
No real build or Simulator test was run after editing, following the supplied
repository instruction. A read-only runtime-list attempt before editing hit
the local sandbox's CoreSimulator XPC restriction; local Xcode reports 27.0.

## Acceptance still pending

Follow the GitHub Actions steps in `TESTING.md` after reviewing and pushing the
changes. A new run must resolve dependencies, build DemoApp, and pass all unit,
StoreKit integration and UI tests before the CI repair can be called successful.
The configured artifact upload includes all phase logs and recursively includes
the result bundle, but an actual failed-run artifact download remains unverified.
If tests still fail under Xcode 27.0, use those logs/result bundles to establish
the cause; do not skip tests, weaken assertions or use `continue-on-error`.

# Validation record — 2026-10-27 (historical)

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
