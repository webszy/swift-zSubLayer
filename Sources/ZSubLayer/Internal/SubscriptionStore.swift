import Foundation

/// Internal seam for deterministic tests. No store implementation leaks into the public API.
@MainActor
protocol SubscriptionStore: AnyObject {
    var onChange: (@MainActor @Sendable () -> Void)? { get set }
    func start(productIDs: [String]) async
    func fetchProducts(productIDs: [String]) async throws -> [SubscriptionProduct]
    func entitlements(productIDs: [String]) async -> [SubscriptionEntitlement]
    func purchase(productID: String) async throws -> PurchaseResult
    func restore() async throws
}

/// Constructed only from verified StoreKit transactions (and verified renewal info for grace).
struct SubscriptionEntitlement: Equatable, Sendable {
    enum State: Hashable, Sendable {
        case active, gracePeriod, billingRetry, expired, revoked, inactive, unknown
    }

    let productID: String
    let state: State
    var expirationDate: Date? = nil
    var gracePeriodExpirationDate: Date? = nil
}

struct AccessSnapshot: Equatable, Sendable {
    var ids: Set<String> = []
    var status: SubscriptionStatus = .inactive
    var nextExpirationDate: Date?

    static func evaluate(_ entitlements: [SubscriptionEntitlement], at now: Date) -> Self {
        var result = Self()
        var activeEnds: [Date] = []
        var graceEnds: [Date] = []
        var states: Set<SubscriptionEntitlement.State> = []

        for entitlement in entitlements {
            states.insert(entitlement.state)
            let end: Date
            switch entitlement.state {
            case .active:
                // An ownership flag or missing expiry must never grant perpetual access.
                guard let expiry = entitlement.expirationDate, expiry > now else {
                    states.insert(.expired)
                    continue
                }
                end = expiry
                activeEnds.append(expiry)
            case .gracePeriod:
                guard let expiry = entitlement.gracePeriodExpirationDate, expiry > now else {
                    states.insert(.expired)
                    continue
                }
                end = expiry
                graceEnds.append(expiry)
            case .billingRetry, .expired, .revoked, .inactive, .unknown:
                continue
            }
            result.ids.insert(entitlement.productID)
            result.nextExpirationDate = min(result.nextExpirationDate ?? end, end)
        }

        if let expiry = activeEnds.max() {
            result.status = .active(expirationDate: expiry)
        } else if let expiry = graceEnds.max() {
            result.status = .gracePeriod(expirationDate: expiry)
        } else if states.contains(.billingRetry) {
            result.status = .billingRetry
        } else if states.contains(.revoked) {
            result.status = .revoked
        } else if states.contains(.expired) {
            result.status = .expired
        } else if states.contains(.unknown) {
            result.status = .unknown
        }
        return result
    }
}
