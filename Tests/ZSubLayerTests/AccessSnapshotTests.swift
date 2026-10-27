import Foundation
import Testing
@testable import ZSubLayer

struct AccessSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: [SubscriptionEntitlement.State.active, .gracePeriod])
    func grantsOnlyUntilTheVerifiedDeadline(state: SubscriptionEntitlement.State) {
        let end = now.addingTimeInterval(10)
        let record = SubscriptionEntitlement(productID: "monthly", state: state,
                                             expirationDate: end, gracePeriodExpirationDate: end)
        #expect(AccessSnapshot.evaluate([record], at: now).ids == ["monthly"])
        #expect(AccessSnapshot.evaluate([record], at: end).ids.isEmpty)
        #expect(AccessSnapshot.evaluate([record], at: end).status == .expired)
    }

    @Test(arguments: [SubscriptionEntitlement.State.active, .gracePeriod])
    func missingDeadlineDoesNotGrantIndefiniteAccess(state: SubscriptionEntitlement.State) {
        let record = SubscriptionEntitlement(productID: "monthly", state: state)
        #expect(AccessSnapshot.evaluate([record], at: now).ids.isEmpty)
    }

    @Test func graceExtendsBeyondNormalExpiryButBillingRetryDoesNot() {
        let expired = now.addingTimeInterval(-10)
        let graceEnd = now.addingTimeInterval(10)
        let grace = SubscriptionEntitlement(productID: "monthly", state: .gracePeriod,
                                            expirationDate: expired, gracePeriodExpirationDate: graceEnd)
        let retry = SubscriptionEntitlement(productID: "monthly", state: .billingRetry,
                                            expirationDate: graceEnd, gracePeriodExpirationDate: graceEnd)
        #expect(AccessSnapshot.evaluate([grace], at: now).status == .gracePeriod(expirationDate: graceEnd))
        #expect(AccessSnapshot.evaluate([grace], at: now).ids == ["monthly"])
        #expect(AccessSnapshot.evaluate([retry], at: now).ids.isEmpty)
        #expect(AccessSnapshot.evaluate([retry], at: now).status == .billingRetry)
    }

    @Test func mixedProductsPreserveOtherEntitlementsAndHaveDeterministicSummary() {
        let short = now.addingTimeInterval(10)
        let long = now.addingTimeInterval(100)
        let records: [SubscriptionEntitlement] = [
            .init(productID: "refunded", state: .revoked),
            .init(productID: "monthly", state: .active, expirationDate: short),
            .init(productID: "yearly", state: .active, expirationDate: long)
        ]
        let snapshot = AccessSnapshot.evaluate(records, at: now)
        #expect(snapshot.ids == ["monthly", "yearly"])
        #expect(snapshot.status == .active(expirationDate: long))
        #expect(snapshot.nextExpirationDate == short)
        #expect(snapshot == AccessSnapshot.evaluate(records.reversed(), at: now))
        #expect(AccessSnapshot.evaluate(records, at: short).ids == ["yearly"])
    }

    @Test func revokedAndExpiredTransactionsCannotUseAFutureCachedExpiry() {
        for state in [SubscriptionEntitlement.State.revoked, .expired, .inactive, .unknown] {
            let record = SubscriptionEntitlement(productID: "monthly", state: state,
                                                 expirationDate: now.addingTimeInterval(100))
            #expect(AccessSnapshot.evaluate([record], at: now).ids.isEmpty)
        }
    }
}
