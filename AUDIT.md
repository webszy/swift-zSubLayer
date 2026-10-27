# Subscription lifecycle review

Scope: ZSubLayer and StoreKitTheKit **1.5.4**, revision
`a77bf8360680241652461f0ac4cb09fdca8c3a48`. Upstream was read, not modified.
The seven requested public APIs, other public model signatures, exact dependency
pin and iOS 15 library minimum remain unchanged. No public protocol, backend or
third-party dependency was added.

| Review area | Finding and repair |
| --- | --- |
| Configure → immediate purchase | Shared startup now publishes readiness inside its task before any waiter returns. All store entry points wait for startup. |
| Repeated configure | First ordering is retained; duplicate IDs are removed. The same set in a different order is idempotent. Replacement sets are rejected without restarting the vendor singleton. |
| Singleton lifetime | The production adapter starts once, retains automatic transaction/status listeners, and cleans up its tasks/monitor when destroyed. Tests create isolated managers through an internal initializer. |
| start/refresh concurrency | MainActor does not serialize work across `await`. Complete store operations are queued; concurrent refreshes share a task and track changes arriving during a read. |
| Purchase success | Access is reconciled before returning. A `.purchased` result alone never fabricates membership; signed transaction history covers delayed current-entitlement enumeration. |
| Renewal/refund/revocation | The old Combine subscription observed only changes to the owned-ID set. Direct StoreKit transaction and subscription-status streams now observe unchanged-ID renewals and signed revocations. |
| Grace | Upstream never populates grace expiry from renewal info. The wrapper verifies transaction and renewal info and requires a future grace deadline. A transient status error can retain an already verified grace deadline for the same transaction, never extend it. |
| Billing retry | Upstream does not resolve Apple's retry status. The wrapper maps it explicitly and never grants access from retry alone. |
| Offline cache | Upstream available-store ownership can outlive cached expiry. The wrapper does not trust vendor keychain/ownership flags. Signed expiry is checked on every `isPremium` read and by a local expiry task, including foreground/time changes. |
| Restore | Upstream absorbs `AppStore.sync()` errors. The adapter calls Apple's sync directly; errors propagate to the host and `lastError`. Successful restore reconciles signed access. |
| Multiple IDs | Selection and display follow configured IDs. Access is a union of valid records; an expired/refunded product doesn't discard another valid subscription. Summary choice is deterministic. |
| Personal and Family Sharing | The same Product ID can have several subscription lineages. Verified evidence is retained by transaction ID and compared only within its original subscription lineage; a newer expired/refunded personal purchase cannot discard valid family access. Signed revocation/upgrade views merge only for the same transaction. |
| Relaunch/foreground/network | Relaunch reads signed state again. Foreground, significant system-time change and network recovery trigger reconciliation. Metadata failure retains previously loaded prices and cannot block a pending revocation read. |
| Swift 6 / state publication | Manager, adapter and internal fake seam are MainActor-isolated; value models and records are Sendable. Combine notifications hop to MainActor before touching published state. Build/test evidence is in `VALIDATION.md`. |

## Upstream limitations contained by the adapter

- `StoreKitTheKit+Subscription.swift` infers state from ownership and cached
  dates; it never returns actual `.revoked` or `.inBillingRetry` states.
- `StoreKitTheKit+StoreSetup.swift` builds subscription info with `isActive:
  true` and nil grace expiry, without independently checking revocation,
  expiry or upgraded transactions. The wrapper verifies these independently.
- `syncWithStore()` skips overlapping calls rather than joining completion,
  and replaces the transaction listener on each sync. The wrapper's refresh
  doesn't use that function as a completion or entitlement authority.
- Published vendor IDs are dispatched asynchronously and only change when
  the set changes; they cannot communicate every subscription lifecycle event.
- Vendor `@unchecked Sendable` and background network sync remain upstream
  implementation details. Wrapper calls are serialized, but this does not prove
  every upstream internal race absent. Upstream source stays unmodified.

## Observable compatibility corrections

The required public signatures are unchanged. `purchase(_:)` before configuration
now consistently throws `.notConfigured`. `refresh()` now propagates metadata
errors (its existing signature already throws), like `loadProducts()` and
`restore()`, while retaining previous metadata. Startup deliberately tolerates
metadata failures so finite signed offline entitlements can still be resolved.

Rollback consists of restoring the original manager/adapter/tests and removing
the new internal seam, example, validation script and related documentation/CI
change. No database or persisted entitlement migration exists. Original files
were preserved locally in `/tmp/zsublayer-original` because the supplied folder
does not contain Git metadata.
