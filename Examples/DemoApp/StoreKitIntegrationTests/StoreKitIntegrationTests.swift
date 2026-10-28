import Foundation
import StoreKit
import StoreKitTest
import Testing
import ZSubLayer

/// A single process-wide StoreKit singleton and test store: never parallelize this suite.
@Suite(.serialized, .timeLimit(.minutes(3)))
@MainActor
struct StoreKitIntegrationTests {
    private static let monthly = "com.example.zsublayer.monthly"
    private static let yearly = "com.example.zsublayer.yearly"

    private func session() async throws -> (SKTestSession, SubscriptionManager) {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "Subscriptions", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.timeRate = .realTime
        let manager = SubscriptionManager.shared
        manager.configure(productIDs: [Self.monthly, Self.yearly])
        try await manager.start()
        // StoreKit's clearTransactions() returns before all signed-history caches settle.
        // Only test setup may poll refresh; purchase and event assertions below must stand alone.
        let deadline = Date().addingTimeInterval(10)
        repeat {
            try await manager.refresh()
            if !manager.isPremium { break }
            guard Date() < deadline else { throw StoreKitWaitError.timeout }
            try await Task.sleep(for: .milliseconds(50))
        } while true
        #expect(!manager.isPremium)
        return (session, manager)
    }

    @Test func localizedProductsAndRealSDKPurchase() async throws {
        let (session, manager) = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let products = try await Product.products(for: [Self.monthly, Self.yearly])
        #expect(manager.products.count == 2)
        for product in products {
            #expect(manager.products.first { $0.id == product.id }?.displayPrice == product.displayPrice)
        }
        #expect(try await manager.purchase(Self.monthly) == .purchased(productID: Self.monthly))
        // Assert immediately: no refresh or retry may hide a purchase/entitlement race.
        #expect(manager.isPremium)
        #expect(manager.activeEntitlements.contains(Self.monthly))
        #expect(session.allTransactions().count == 1)
    }

    @Test func externalPurchaseAndRenewalReachTheBuiltInListeners() async throws {
        let (session, manager) = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        let original = try await session.buyProduct(identifier: Self.monthly)
        try await waitFor { manager.isPremium }
        let firstExpiry = try #require(original.expirationDate)
        try session.forceRenewalOfSubscription(productIdentifier: Self.monthly)
        try await waitFor {
            if case .active(let expiry) = manager.subscriptionStatus { return (expiry ?? .distantPast) > firstExpiry }
            return false
        }
        #expect(manager.activeEntitlements == [Self.monthly])
    }

    @Test func expirationRemovesAccessAutomatically() async throws {
        let (session, manager) = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        session.timeRate = .oneRenewalEveryTwoSeconds
        _ = try await manager.purchase(Self.monthly)
        #expect(manager.isPremium)
        let transaction = try #require(session.allTransactions().last)
        try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        try await waitFor { !manager.isPremium && manager.subscriptionStatus == .expired }
        #expect(manager.activeEntitlements.isEmpty)
    }

    @Test func refundRevokesAccessAutomatically() async throws {
        let (session, manager) = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        _ = try await manager.purchase(Self.yearly)
        #expect(manager.isPremium)
        let transaction = try #require(session.allTransactions().last)
        try session.refundTransaction(identifier: transaction.identifier)
        try await waitFor { !manager.isPremium && manager.subscriptionStatus == .revoked }
    }

    @Test func pendingApprovalDoesNotUnlockUntilApproved() async throws {
        let (session, manager) = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        session.askToBuyEnabled = true
        #expect(try await manager.purchase(Self.monthly) == .pending)
        #expect(!manager.isPremium)
        let pending = try #require(session.allTransactions().last)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await waitFor { manager.isPremium }
    }

    @Test func cancellationErrorInjectionCannotInventAccess() async throws {
        let (session, manager) = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        do {
            #expect(try await manager.purchase(Self.monthly) == .cancelled)
        } catch let error as SubscriptionError {
            // iOS 27's local service can lose the injected cancellation and return .unknown.
            // Preserve a real failure in that case. Actual UI cancellation has a separate UI test.
            guard case .purchaseFailed(let message) = error else { throw error }
            #expect(!message.isEmpty)
            #expect(manager.lastError == error.localizedDescription)
        }
        #expect(!manager.isPremium)
    }

    @Test func failedPurchasesRemainLocked() async throws {
        let (session, manager) = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)
        await #expect(throws: SubscriptionError.self) { try await manager.purchase(Self.monthly) }
        #expect(!manager.isPremium && manager.lastError != nil)
    }

    @Test func restoreSyncsAndPropagatesStoreKitErrors() async throws {
        let (session, manager) = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        _ = try await session.buyProduct(identifier: Self.monthly)
        try await manager.restore()
        #expect(manager.isPremium)
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .appStoreSync)
        await #expect(throws: (any Error).self) { try await manager.restore() }
        #expect(manager.lastError != nil)
        #expect(manager.isPremium)
    }

    @Test(arguments: [false, true])
    func billingRetryAndGraceFollowVerifiedRenewalState(grace: Bool) async throws {
        let (session, manager) = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        session.shouldEnterBillingRetryOnRenewal = true
        session.billingGracePeriodIsEnabled = grace
        session.timeRate = .realTime
        // Generate a real signed purchase and its first failed renewal together.
        // A past anniversary makes renewUntilNow process the renewal in this
        // call, without relying on a delayed background renewal timer.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let deadline = Date().addingTimeInterval(-30)
        // A monthly anniversary may not exist at month-end; yearly covers that
        // case, while monthly covers February 29 in a year after a leap year.
        let candidates: [(String, Calendar.Component)] = [(Self.monthly, .month), (Self.yearly, .year)]
        let (productID, purchaseDate) = try #require(candidates.compactMap { id, period -> (String, Date)? in
            guard let date = calendar.date(byAdding: period, value: -1, to: deadline),
                  let anniversary = calendar.date(byAdding: period, value: 1, to: date),
                  abs(anniversary.timeIntervalSince(deadline)) < 1 else { return nil }
            return (id, date)
        }.first)
        let purchased = try await session.buyProduct(
            identifier: productID, options: [.purchaseDate(purchaseDate, renewalBehavior: .renewUntilNow)]
        )
        let expiry = try #require(purchased.expirationDate)
        try #require(purchased.environment == .xcode)
        try #require(expiry < Date() && abs(expiry.timeIntervalSince(deadline)) < 1)
        try #require(session.allTransactions().contains { $0.hasPurchaseIssue })
        do {
            // Observe the SDK's own listeners; never refresh to deliver this event.
            // Real-time retry/grace remain valid throughout CI synchronization.
            try await waitFor(timeout: 150) {
                if grace {
                    if case .gracePeriod = manager.subscriptionStatus { return manager.isPremium }
                } else if manager.subscriptionStatus == .billingRetry { return !manager.isPremium }
                return false
            }
        } catch StoreKitWaitError.timeout {
            let product = try await Product.products(for: [productID]).first
            let statuses = try await product?.subscription?.status ?? []
            throw StoreKitWaitError.renewalTimeout(
                grace: grace, manager: String(describing: manager.subscriptionStatus),
                store: statuses.map { String(describing: $0.state) }
            )
        }
        if grace {
            guard case .gracePeriod(let expiry) = manager.subscriptionStatus else {
                Issue.record("Expected verified grace period")
                return
            }
            #expect(try #require(expiry) > Date())
        } else {
            #expect(manager.activeEntitlements.isEmpty)
        }
    }

    @Test func metadataNetworkFailureRecoversWithoutLosingPaidAccess() async throws {
        let (session, manager) = try await session()
        defer { session.clearTransactions(); session.resetToDefaultState() }
        _ = try await manager.purchase(Self.monthly)
        let products = manager.products
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        await #expect(throws: (any Error).self) { try await manager.refresh() }
        #expect(manager.products == products && manager.isPremium)
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        try await manager.refresh()
        #expect(manager.isPremium && manager.lastError == nil)
    }

    private func waitFor(timeout: TimeInterval = 10, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { throw StoreKitWaitError.timeout }
            // Poll only external StoreKit delivery, with a deadline; never manufacture an event.
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private final class BundleMarker: NSObject {}
private enum StoreKitWaitError: Error {
    case timeout
    case renewalTimeout(grace: Bool, manager: String, store: [String])
}
