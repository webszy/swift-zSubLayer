import Foundation

/// Value evidence extracted only after StoreKit verifies an auto-renewable transaction.
struct VerifiedSubscriptionTransaction: Sendable {
    let id: UInt64
    let originalID: UInt64
    let productID: String
    let purchaseDate: Date
    let expirationDate: Date?
    var isRevoked = false
    var isUpgraded = false

    var entitlement: SubscriptionEntitlement {
        if isRevoked { return .init(productID: productID, state: .revoked) }
        if isUpgraded { return .init(productID: productID, state: .inactive) }
        return .init(productID: productID, state: .active, expirationDate: expirationDate)
    }
}

struct VerifiedSubscriptionStatus: Sendable {
    let transaction: VerifiedSubscriptionTransaction
    let state: SubscriptionEntitlement.State
    var gracePeriodExpirationDate: Date?
}

enum SubscriptionEvidence {
    static func resolve(
        transactions: [VerifiedSubscriptionTransaction],
        statuses: [VerifiedSubscriptionStatus],
        graceFallback: [UInt64: SubscriptionEntitlement] = [:]
    ) -> [SubscriptionEntitlement] {
        // A Product ID can have personal and family-shared lineages simultaneously.
        // Merge signed views by transaction ID; compare recency only within one lineage.
        var byID: [UInt64: VerifiedSubscriptionTransaction] = [:]
        for transaction in transactions + statuses.map(\.transaction) {
            var merged = transaction
            if let previous = byID[transaction.id] {
                merged.isRevoked = merged.isRevoked || previous.isRevoked
                merged.isUpgraded = merged.isUpgraded || previous.isUpgraded
            }
            byID[transaction.id] = merged
        }
        var newest: [UInt64: VerifiedSubscriptionTransaction] = [:]
        for transaction in byID.values {
            if let previous = newest[transaction.originalID], isNewer(previous, than: transaction) { continue }
            newest[transaction.originalID] = transaction
        }

        var resolvedLineages: Set<UInt64> = []
        var records: [SubscriptionEntitlement] = []
        for status in statuses {
            guard let transaction = byID[status.transaction.id],
                  newest[transaction.originalID]?.id == transaction.id else { continue }
            resolvedLineages.insert(transaction.originalID)
            let base = transaction.entitlement
            if base.state == .revoked || base.state == .inactive {
                records.append(base)
            } else {
                records.append(.init(productID: transaction.productID, state: status.state,
                                     expirationDate: transaction.expirationDate,
                                     gracePeriodExpirationDate: status.gracePeriodExpirationDate))
            }
        }
        for transaction in newest.values where !resolvedLineages.contains(transaction.originalID) {
            let base = transaction.entitlement
            if base.state == .active, let grace = graceFallback[transaction.id] {
                records.append(grace)
            } else {
                records.append(base)
            }
        }
        return records
    }

    private static func isNewer(_ lhs: VerifiedSubscriptionTransaction, than rhs: VerifiedSubscriptionTransaction) -> Bool {
        if lhs.purchaseDate != rhs.purchaseDate { return lhs.purchaseDate > rhs.purchaseDate }
        return lhs.id > rhs.id
    }
}
