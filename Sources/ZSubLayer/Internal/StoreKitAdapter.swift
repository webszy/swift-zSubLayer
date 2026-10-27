import Foundation
import Network
import StoreKit
import StoreKitTheKit

/// The only layer that references vendor types. Vendor ownership/cache flags are not authority.
@MainActor
final class StoreKitAdapter: SubscriptionStore {
    var onChange: (@MainActor @Sendable () -> Void)?

    private let store = StoreKitTheKit.shared
    private let networkMonitor = NWPathMonitor()
    private var startupTask: Task<Void, Never>?
    private var transactionTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var storeProducts: [String: Product] = [:]
    private var configuredIDs: Set<String> = []
    private var wasOnline = false
    private var verifiedGrace: [UInt64: SubscriptionEntitlement] = [:]

    deinit {
        transactionTask?.cancel()
        statusTask?.cancel()
        networkMonitor.cancel()
    }

    func start(productIDs: [String]) async {
        if let startupTask {
            await startupTask.value
            return
        }
        configuredIDs = Set(productIDs)
        // Keep our observers for the adapter's lifetime: upstream replaces its listener on sync.
        transactionTask = Task { [weak self] in
            for await verification in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = verification,
                      transaction.productType == .autoRenewable else { continue }
                // An upgrade to an unconfigured sibling can invalidate a configured product.
                self?.onChange?()
                // Upstream finishes after delivery; signed history includes finished transactions.
            }
        }
        statusTask = Task { [weak self] in
            for await status in Product.SubscriptionInfo.Status.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = status.transaction,
                      transaction.productType == .autoRenewable else { continue }
                self?.onChange?()
            }
        }
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recovered = online && !self.wasOnline
                self.wasOnline = online
                if recovered { self.onChange?() }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "ZSubLayer.network"))
        let task = Task { [store] in
            await store.start(iapItems: productIDs.map {
                Purchasable(bundleId: $0, type: .autoRenewableSubscription)
            })
        }
        startupTask = task
        await task.value
    }

    func purchase(productID: String) async throws -> PurchaseResult {
        let item = Purchasable(bundleId: productID, type: .autoRenewableSubscription)
        switch await store.purchaseElement(element: item) {
        case .purchaseCompleted(let purchased):
            return .purchased(productID: purchased.bundleId)
        case .purchaseFailure(let error):
            switch error {
            case .userCancelled: return .cancelled
            case .pendingPurchase: return .pending
            case .productNotFound: throw SubscriptionError.productUnavailable(productID)
            case .unverifiedPurchase: throw SubscriptionError.verificationFailed
            case .purchaseError(let underlying):
                if let error = underlying as? StoreKitError, case .userCancelled = error {
                    return .cancelled
                }
                throw SubscriptionError.purchaseFailed(underlying.localizedDescription)
            default: throw SubscriptionError.purchaseFailed(String(describing: error))
            }
        }
    }

    func restore() async throws {
        // Upstream restorePurchases() absorbs this error.
        try await AppStore.sync()
    }

    func fetchProducts(productIDs: [String]) async throws -> [SubscriptionProduct] {
        let fetched = try await Product.products(for: productIDs)
        storeProducts = Dictionary(uniqueKeysWithValues: fetched
            .filter { $0.type == .autoRenewable }
            .map { ($0.id, $0) })
        return productIDs.compactMap { id in
            guard let product = storeProducts[id] else { return nil }
            let period = product.subscription?.subscriptionPeriod
            let unit: SubscriptionPeriod.Unit?
            switch period?.unit {
            case .day?: unit = .day
            case .week?: unit = .week
            case .month?: unit = .month
            case .year?: unit = .year
            default: unit = nil
            }
            return SubscriptionProduct(
                id: product.id,
                displayName: product.displayName,
                productDescription: product.description,
                displayPrice: product.displayPrice,
                period: unit.flatMap { unit in period.map { .init(value: $0.value, unit: unit) } }
            )
        }
    }

    func entitlements(productIDs: [String]) async -> [SubscriptionEntitlement] {
        var transactions: [VerifiedSubscriptionTransaction] = []
        var unverifiedIDs: Set<String> = []
        var groups = Set(storeProducts.values.compactMap { $0.subscription?.subscriptionGroupID })
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  configuredIDs.contains(transaction.productID),
                  let evidence = Self.evidence(for: transaction) else { continue }
            transactions.append(evidence)
            if let group = transaction.subscriptionGroupID { groups.insert(group) }
        }
        // Preserve every current lineage. A product-wide latest transaction may belong to a
        // different, individually owned or family-shared subscription and cannot replace them.
        for id in productIDs {
            guard let result = await StoreKit.Transaction.latest(for: id) else { continue }
            switch result {
            case .verified(let transaction):
                if let evidence = Self.evidence(for: transaction) { transactions.append(evidence) }
                if let group = transaction.subscriptionGroupID { groups.insert(group) }
            case .unverified:
                unverifiedIDs.insert(id)
            }
        }

        var statuses: [VerifiedSubscriptionStatus] = []
        for group in groups {
            // A failed request uses finite signed transaction/grace evidence below.
            guard let fetched = try? await Product.SubscriptionInfo.status(for: group) else { continue }
            for status in fetched {
                guard case .verified(let transaction) = status.transaction,
                      configuredIDs.contains(transaction.productID),
                      let evidence = Self.evidence(for: transaction) else { continue }
                let state: SubscriptionEntitlement.State
                var graceEnd: Date?
                switch status.state {
                case .subscribed: state = .active
                case .inGracePeriod:
                    if case .verified(let renewal) = status.renewalInfo {
                        state = .gracePeriod
                        graceEnd = renewal.gracePeriodExpirationDate
                    } else {
                        state = .unknown
                    }
                case .inBillingRetryPeriod: state = .billingRetry
                case .expired: state = .expired
                case .revoked: state = .revoked
                default: state = .unknown
                }
                statuses.append(.init(transaction: evidence, state: state, gracePeriodExpirationDate: graceEnd))
                if state == .gracePeriod, evidence.entitlement.state == .active {
                    verifiedGrace[transaction.id] = .init(productID: transaction.productID, state: .gracePeriod,
                                                          gracePeriodExpirationDate: graceEnd)
                } else {
                    verifiedGrace[transaction.id] = nil
                }
            }
        }
        let observedIDs = Set(transactions.map(\.id) + statuses.map { $0.transaction.id })
        verifiedGrace = verifiedGrace.filter { observedIDs.contains($0.key) }
        let records = SubscriptionEvidence.resolve(transactions: transactions, statuses: statuses,
                                                   graceFallback: verifiedGrace)
        return productIDs.flatMap { id -> [SubscriptionEntitlement] in
            let matching = records.filter { $0.productID == id }
            if !matching.isEmpty { return matching }
            return [.init(productID: id, state: unverifiedIDs.contains(id) ? .unknown : .inactive)]
        }
    }

    private static func evidence(for transaction: StoreKit.Transaction) -> VerifiedSubscriptionTransaction? {
        guard transaction.productType == .autoRenewable else { return nil }
        return .init(id: transaction.id, originalID: transaction.originalID, productID: transaction.productID,
                     purchaseDate: transaction.purchaseDate, expirationDate: transaction.expirationDate,
                     isRevoked: transaction.revocationDate != nil, isUpgraded: transaction.isUpgraded)
    }
}
