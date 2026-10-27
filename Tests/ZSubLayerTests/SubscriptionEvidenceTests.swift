import Foundation
import Testing
@testable import ZSubLayer

struct SubscriptionEvidenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func transaction(_ id: UInt64, lineage: UInt64, expiry: TimeInterval,
                             revoked: Bool = false, upgraded: Bool = false) -> VerifiedSubscriptionTransaction {
        .init(id: id, originalID: lineage, productID: "monthly",
              purchaseDate: now.addingTimeInterval(TimeInterval(id)),
              expirationDate: now.addingTimeInterval(expiry), isRevoked: revoked, isUpgraded: upgraded)
    }

    @Test(arguments: [SubscriptionEntitlement.State.expired, .revoked, .billingRetry])
    func personalFailureCannotRemoveAnotherFamilyLineage(state: SubscriptionEntitlement.State) {
        let family = transaction(1, lineage: 100, expiry: 100)
        let personal = transaction(2, lineage: 200, expiry: -1, revoked: state == .revoked)
        let statuses: [VerifiedSubscriptionStatus] = [
            .init(transaction: family, state: .active), .init(transaction: personal, state: state)
        ]
        let records = SubscriptionEvidence.resolve(transactions: [family, personal], statuses: statuses)
        let snapshot = AccessSnapshot.evaluate(records, at: now)
        #expect(snapshot.ids == ["monthly"])
        #expect(snapshot.status == .active(expirationDate: family.expirationDate))
    }

    @Test func offlineCurrentFamilyEntitlementSurvivesNewerExpiredPersonalHistory() {
        let family = transaction(1, lineage: 100, expiry: 100)
        let expiredPersonal = transaction(2, lineage: 200, expiry: -1)
        let records = SubscriptionEvidence.resolve(transactions: [family, expiredPersonal], statuses: [])
        #expect(AccessSnapshot.evaluate(records, at: now).ids == ["monthly"])
        #expect(AccessSnapshot.evaluate(records, at: now.addingTimeInterval(100)).ids.isEmpty)
    }

    @Test func newerRevocationOfTheSameLineageDefeatsAStaleActiveStatus() {
        let old = transaction(1, lineage: 100, expiry: 100)
        let latest = transaction(2, lineage: 100, expiry: 200, revoked: true)
        let records = SubscriptionEvidence.resolve(transactions: [old, latest],
                                                  statuses: [.init(transaction: old, state: .active)])
        #expect(AccessSnapshot.evaluate(records, at: now).ids.isEmpty)
        #expect(AccessSnapshot.evaluate(records, at: now).status == .revoked)
    }

    @Test(arguments: [false, true])
    func signedInvalidationOfTheSameTransactionWinsInEitherReadOrder(upgraded: Bool) {
        let stale = transaction(1, lineage: 100, expiry: 100)
        let invalid = transaction(1, lineage: 100, expiry: 100, revoked: !upgraded, upgraded: upgraded)
        for (history, status) in [(stale, invalid), (invalid, stale)] {
            let records = SubscriptionEvidence.resolve(transactions: [history],
                                                      statuses: [.init(transaction: status, state: .active)])
            #expect(AccessSnapshot.evaluate(records, at: now).ids.isEmpty)
        }
    }

    @Test func graceCacheIsBoundToOneVerifiedTransaction() {
        let family = transaction(1, lineage: 100, expiry: -10)
        let personal = transaction(2, lineage: 200, expiry: -1)
        let grace = SubscriptionEntitlement(productID: "monthly", state: .gracePeriod,
                                             gracePeriodExpirationDate: now.addingTimeInterval(10))
        let records = SubscriptionEvidence.resolve(transactions: [family, personal], statuses: [],
                                                  graceFallback: [family.id: grace])
        #expect(AccessSnapshot.evaluate(records, at: now).ids == ["monthly"])
        #expect(AccessSnapshot.evaluate(records, at: now.addingTimeInterval(10)).ids.isEmpty)
        let renewed = transaction(3, lineage: 100, expiry: -1)
        let replaced = SubscriptionEvidence.resolve(transactions: [family, renewed, personal], statuses: [],
                                                   graceFallback: [family.id: grace])
        #expect(AccessSnapshot.evaluate(replaced, at: now).ids.isEmpty)
    }
}
