import Combine
import Foundation
import Testing
import UIKit
@testable import ZSubLayer

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SubscriptionManagerTests {
    private let store = FakeSubscriptionStore()
    private let clock = TestClock()

    private func manager(observesLifecycle: Bool = false) -> SubscriptionManager {
        SubscriptionManager(adapter: store, observesLifecycle: observesLifecycle, now: { clock.date })
    }
    private func active(_ id: String = "monthly", seconds: TimeInterval = 100) -> SubscriptionEntitlement {
        .init(productID: id, state: .active, expirationDate: clock.date.addingTimeInterval(seconds))
    }

    @Test func unconfiguredHasNoInventedEntitlements() async {
        let manager = manager()
        #expect(manager.products.isEmpty)
        #expect(manager.subscriptionStatus == .unknown)
        #expect(!manager.isReady && !manager.isLoading && !manager.isPremium)
        await #expect(throws: SubscriptionError.notConfigured) { try await manager.start() }
        await #expect(throws: SubscriptionError.notConfigured) { try await manager.purchase() }
        await #expect(throws: SubscriptionError.notConfigured) { try await manager.purchase("monthly") }
        await #expect(throws: SubscriptionError.notConfigured) { try await manager.restore() }
        await #expect(throws: SubscriptionError.notConfigured) { try await manager.refresh() }
        await #expect(throws: SubscriptionError.notConfigured) { try await manager.loadProducts() }
        #expect(store.startCalls == 0)
    }

    @Test func immediatePurchaseWaitsForStartupAndPublishesBeforeReturning() async throws {
        let manager = manager()
        let gate = TestGate()
        store.startGate = gate
        store.outcome = .success(.purchased(productID: "monthly"))
        store.afterPurchase = [active()]
        manager.configure(productIDs: ["monthly"])
        let purchase = Task { try await manager.purchase() }
        await gate.waitUntilEntered()
        #expect(manager.isLoading && !manager.isReady)
        #expect(store.purchasedIDs.isEmpty)
        gate.open()
        #expect(try await purchase.value == .purchased(productID: "monthly"))
        #expect(manager.isReady && manager.isPremium)
        #expect(manager.activeEntitlements == ["monthly"])
        #expect(!manager.isLoading)
        #expect(store.startCalls == 1)
    }

    @Test func multipleProductsRequireAnExplicitID() async throws {
        let manager = manager()
        manager.configure(productIDs: ["yearly", "monthly"])
        await #expect(throws: SubscriptionError.multipleProductsRequireID) { try await manager.purchase() }
        store.outcome = .success(.purchased(productID: "yearly"))
        store.afterPurchase = [active("yearly")]
        #expect(try await manager.purchase("yearly") == .purchased(productID: "yearly"))
        #expect(store.purchasedIDs == ["yearly"])
        #expect(manager.products.map(\.id) == ["yearly", "monthly"])
        #expect(manager.isPremium)
    }

    @Test func unknownAndUnavailableProductsNeverReachPurchase() async throws {
        let manager = manager()
        manager.configure(productIDs: ["missing"])
        await #expect(throws: SubscriptionError.invalidProductID("other")) { try await manager.purchase("other") }
        await #expect(throws: SubscriptionError.productUnavailable("missing")) { try await manager.purchase() }
        #expect(store.purchasedIDs.isEmpty)
        #expect(!manager.isPremium)
        #expect(manager.lastError != nil)
    }

    @Test(arguments: [PurchaseResult.cancelled, .pending])
    func nonPurchaseOutcomesDoNotUnlock(result: PurchaseResult) async throws {
        let manager = manager()
        store.outcome = .success(result)
        manager.configure(productIDs: ["monthly"])
        #expect(try await manager.purchase() == result)
        #expect(!manager.isPremium && manager.lastError == nil && !manager.isLoading)
    }

    @Test(arguments: [SubscriptionError.purchaseFailed("network"), .verificationFailed, .storeUnavailable])
    func purchaseErrorsPropagate(error: SubscriptionError) async throws {
        let manager = manager()
        store.outcome = .failure(error)
        manager.configure(productIDs: ["monthly"])
        await #expect(throws: error) { try await manager.purchase() }
        #expect(manager.lastError == error.localizedDescription)
        #expect(!manager.isPremium && !manager.isLoading)
    }

    @Test func successWithoutVerifiedEntitlementDoesNotInventAccess() async throws {
        let manager = manager()
        store.outcome = .success(.purchased(productID: "monthly"))
        manager.configure(productIDs: ["monthly"])
        _ = try await manager.purchase()
        #expect(!manager.isPremium)
        #expect(manager.subscriptionStatus == .inactive)
    }

    @Test func restorePublishesAndPropagatesFailures() async throws {
        let manager = manager()
        manager.configure(productIDs: ["monthly"])
        store.afterRestore = [active()]
        try await manager.restore()
        #expect(manager.isPremium)
        store.restoreError = .storeUnavailable
        await #expect(throws: SubscriptionError.storeUnavailable) { try await manager.restore() }
        #expect(manager.isPremium)
        #expect(manager.lastError == SubscriptionError.storeUnavailable.localizedDescription)
        #expect(!manager.isLoading)
        store.restoreError = nil
        store.afterRestore = []
        try await manager.restore()
        #expect(!manager.isPremium && manager.lastError == nil)
    }

    @Test func configurationIsSetIdempotentAndRejectsReplacement() async throws {
        let manager = manager()
        manager.configure(productIDs: ["", "yearly", "monthly", "yearly"])
        manager.configure(productIDs: ["monthly", "yearly"])
        async let first: Void = manager.start()
        async let second: Void = manager.start()
        _ = try await (first, second)
        #expect(manager.productIDs == ["yearly", "monthly"])
        #expect(store.startCalls == 1)
        #expect(manager.lastError == nil)
        manager.configure(productIDs: ["other"])
        #expect(manager.productIDs == ["yearly", "monthly"])
        #expect(manager.lastError != nil)
        manager.configure(productIDs: [])
        #expect(store.startCalls == 1)
    }

    @Test func emptyConfigurationCanBeCorrected() async throws {
        let manager = manager()
        manager.configure(productIDs: [""])
        #expect(!manager.isReady && manager.productIDs.isEmpty)
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        #expect(manager.isReady && manager.lastError == nil)
    }

    @Test func concurrentPurchasesOfSameProductShareOneStorePurchase() async throws {
        let manager = manager()
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        let gate = TestGate()
        store.purchaseGate = gate
        store.outcome = .success(.purchased(productID: "monthly"))
        store.afterPurchase = [active()]
        let first = Task { try await manager.purchase() }
        await gate.waitUntilEntered()
        let secondEntered = TestGate()
        let second = Task { secondEntered.open(); return try await manager.purchase() }
        await secondEntered.wait()
        #expect(manager.isLoading)
        gate.open()
        let results = try await [first.value, second.value]
        #expect(results == [.purchased(productID: "monthly"), .purchased(productID: "monthly")])
        #expect(store.purchasedIDs == ["monthly"])
        #expect(!manager.isLoading)
    }

    @Test func purchaseRestoreAndRefreshNeverOverlapStoreCalls() async throws {
        let manager = manager()
        manager.configure(productIDs: ["monthly", "yearly"])
        try await manager.start()
        let gate = TestGate()
        store.purchaseGate = gate
        let purchase = Task { try await manager.purchase("monthly") }
        await gate.waitUntilEntered()
        async let restored: Void = manager.restore()
        async let refreshed: Void = manager.refresh()
        async let loaded: Void = manager.loadProducts()
        gate.open()
        _ = try await (purchase.value, restored, refreshed, loaded)
        #expect(store.maximumConcurrentCalls == 1)
        #expect(store.restoreCalls == 1 && !manager.isLoading)
    }

    @Test func refreshesCoalesceAndDoNotLoseAnUpdateDuringARead() async throws {
        let manager = manager()
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        let gate = TestGate()
        store.snapshotGate = gate
        let first = Task { try await manager.refresh() }
        await gate.waitUntilEntered()
        store.records = [active()]
        store.onChange?()
        let second = Task { try await manager.refresh() }
        gate.open()
        _ = try await (first.value, second.value)
        #expect(manager.isPremium)
        #expect(store.maximumConcurrentCalls == 1)
    }

    @Test(arguments: [SubscriptionEntitlement.State.expired, .revoked, .billingRetry, .unknown])
    func lossOfAccessIsPublishedEvenWhenProductIDsDoNotChange(state: SubscriptionEntitlement.State) async throws {
        let manager = manager()
        store.records = [active()]
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        #expect(manager.isPremium)
        store.records = [.init(productID: "monthly", state: state)]
        try await manager.refresh()
        #expect(!manager.isPremium && manager.activeEntitlements.isEmpty)
    }

    @Test func offlineAccessExpiresWithoutNetworkOrAStoreEvent() async throws {
        let manager = manager()
        store.records = [active(seconds: 10)]
        store.productError = .storeUnavailable
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        #expect(manager.isReady && manager.isPremium)
        clock.date.addTimeInterval(10)
        // The read itself is safe even before the suspended expiry task can execute.
        #expect(!manager.isPremium)
        manager.revalidateEntitlements()
        #expect(manager.subscriptionStatus == .expired && manager.activeEntitlements.isEmpty)
        await #expect(throws: SubscriptionError.storeUnavailable) { try await manager.refresh() }
        #expect(!manager.isPremium)
    }

    @Test func offlineStartupRecoversProductsAndEntitlements() async throws {
        let manager = manager()
        store.productError = .storeUnavailable
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        #expect(manager.products.isEmpty && manager.lastError != nil)
        store.productError = nil
        store.records = [active()]
        store.onChange?()
        try await manager.refresh()
        #expect(manager.isPremium && manager.products.count == 1 && manager.lastError == nil)
    }

    @Test func metadataErrorsPreserveLoadedPricesAndPropagate() async throws {
        let manager = manager()
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        let products = manager.products
        store.productError = .storeUnavailable
        await #expect(throws: SubscriptionError.storeUnavailable) { try await manager.loadProducts() }
        await #expect(throws: SubscriptionError.storeUnavailable) { try await manager.refresh() }
        #expect(manager.products == products)
        #expect(manager.lastError != nil && !manager.isLoading)
    }

    @Test func metadataFailureCannotHideARefundArrivingDuringRefresh() async throws {
        let manager = manager()
        store.records = [active()]
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        let gate = TestGate()
        store.snapshotGate = gate
        store.productError = .storeUnavailable
        let refresh = Task { try await manager.refresh() }
        await gate.waitUntilEntered()
        store.records = [.init(productID: "monthly", state: .revoked)]
        store.onChange?()
        gate.open()
        await #expect(throws: SubscriptionError.storeUnavailable) { try await refresh.value }
        #expect(!manager.isPremium && manager.subscriptionStatus == .revoked)
    }

    @Test func recordsForUnconfiguredProductsCannotGrantAccess() async throws {
        let manager = manager()
        store.records = [active("other")]
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        #expect(!manager.isPremium && manager.activeEntitlements.isEmpty)
    }

    @Test func restoredProcessReadsSignedStateAgain() async throws {
        let first = manager()
        store.records = [active()]
        first.configure(productIDs: ["monthly"])
        try await first.start()
        let otherStore = FakeSubscriptionStore()
        otherStore.records = store.records
        let restarted = SubscriptionManager(adapter: otherStore, now: { clock.date })
        restarted.configure(productIDs: ["monthly"])
        try await restarted.start()
        #expect(restarted.isPremium)
        #expect(otherStore.startCalls == 1)
    }

    @Test func foregroundRefreshesWithoutHostTransactionListener() async throws {
        let manager = manager(observesLifecycle: true)
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        store.records = [active()]
        let read = TestGate()
        store.onRead = { read.open() }
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await read.wait()
        try await manager.refresh()
        #expect(manager.isPremium)
    }

    @Test func cancelledCallerDoesNotStartAPurchase() async throws {
        let manager = manager()
        let gate = TestGate()
        store.startGate = gate
        manager.configure(productIDs: ["monthly"])
        let purchase = Task { try await manager.purchase() }
        await gate.waitUntilEntered()
        purchase.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await purchase.value }
        #expect(store.purchasedIDs.isEmpty)
    }

    @Test func entitlementPublishingStaysOnMainActor() async throws {
        let manager = manager()
        var publications = 0
        let token = manager.$activeEntitlements.sink { _ in
            MainActor.assertIsolated()
            publications += 1
        }
        store.records = [active()]
        manager.configure(productIDs: ["monthly"])
        try await manager.start()
        #expect(publications >= 2)
        withExtendedLifetime(token) {}
    }
}
