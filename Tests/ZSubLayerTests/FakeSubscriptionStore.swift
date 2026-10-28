import Foundation
@testable import ZSubLayer

@MainActor
final class TestGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
final class FakeSubscriptionStore: SubscriptionStore {
    var onChange: (@MainActor @Sendable () -> Void)?
    var availableIDs: [String] = ["monthly", "yearly"]
    var records: [SubscriptionEntitlement] = []
    var afterPurchase: [SubscriptionEntitlement] = []
    var afterRestore: [SubscriptionEntitlement] = []
    var outcome: Result<PurchaseResult, SubscriptionError> = .success(.cancelled)
    var productError: SubscriptionError?
    var restoreError: SubscriptionError?
    var startGate: TestGate?
    var purchaseGate: TestGate?
    var restoreGate: TestGate?
    var snapshotGate: TestGate?
    var fetchGate: TestGate?
    var onRead: (@MainActor () -> Void)?
    private(set) var startCalls = 0
    private(set) var fetchCalls = 0
    private(set) var snapshotCalls = 0
    private(set) var purchasedIDs: [String] = []
    private(set) var restoreCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private var concurrentCalls = 0

    func start(productIDs: [String]) async {
        enter(); defer { leave() }
        startCalls += 1
        await startGate?.wait()
    }

    func fetchProducts(productIDs: [String]) async throws -> [SubscriptionProduct] {
        enter(); defer { leave() }
        fetchCalls += 1
        await fetchGate?.wait()
        if let productError { throw productError }
        return productIDs.filter { availableIDs.contains($0) }.map {
            .init(id: $0, displayName: $0, productDescription: "Test subscription",
                  displayPrice: "$1.00", period: .init(value: 1, unit: .month))
        }
    }

    func entitlements(productIDs: [String]) async -> [SubscriptionEntitlement] {
        enter(); defer { leave() }
        snapshotCalls += 1
        let captured = records
        onRead?()
        await snapshotGate?.wait()
        return captured
    }

    func purchase(productID: String) async throws -> PurchaseResult {
        enter(); defer { leave() }
        purchasedIDs.append(productID)
        await purchaseGate?.wait()
        let result = try outcome.get()
        if case .purchased = result { records = afterPurchase }
        return result
    }

    func restore() async throws {
        enter(); defer { leave() }
        restoreCalls += 1
        await restoreGate?.wait()
        if let restoreError { throw restoreError }
        records = afterRestore
    }

    private func enter() {
        concurrentCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
    }
    private func leave() { concurrentCalls -= 1 }
}
