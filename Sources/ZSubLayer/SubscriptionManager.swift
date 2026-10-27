import Combine
import Foundation
import StoreKit
import UIKit

/// Configure at launch, then purchase, restore and observe membership on the main actor.
@MainActor
public final class SubscriptionManager: ObservableObject {
    public static let shared = SubscriptionManager(adapter: StoreKitAdapter(), observesLifecycle: true)

    @Published public private(set) var products: [SubscriptionProduct] = []
    @Published public private(set) var subscriptionStatus: SubscriptionStatus = .unknown
    @Published public private(set) var activeEntitlements: Set<String> = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isReady = false
    @Published public private(set) var lastError: String?

    /// Checks the verified expiry even if a suspended app hasn't delivered its expiry timer yet.
    public var isPremium: Bool { !AccessSnapshot.evaluate(entitlements, at: now()).ids.isEmpty }
    public private(set) var productIDs: [String] = []

    private let adapter: any SubscriptionStore
    private let now: @MainActor @Sendable () -> Date
    private var entitlements: [SubscriptionEntitlement] = []
    private var startTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Error>?
    private var operationTail: Task<Void, Never>?
    private var purchases: [String: Task<PurchaseResult, Error>] = [:]
    private var expiryTask: Task<Void, Never>?
    private var pendingOperations = 0
    private var changeGeneration: UInt64 = 0
    private var reconciledGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()

    /// Internal injection only; applications always use shared.
    init(adapter: any SubscriptionStore, observesLifecycle: Bool = false,
         now: @escaping @MainActor @Sendable () -> Date = { Date() }) {
        self.adapter = adapter
        self.now = now
        adapter.onChange = { [weak self] in self?.storeDidChange() }
        if observesLifecycle {
            for name in [UIApplication.didBecomeActiveNotification, UIApplication.significantTimeChangeNotification] {
                NotificationCenter.default.publisher(for: name)
                    .sink { [weak self] _ in
                        Task { @MainActor [weak self] in self?.storeDidChange() }
                    }
                    .store(in: &cancellables)
            }
        }
    }

    deinit { expiryTask?.cancel() }

    /// Starts automatically. The same set is idempotent; a different set is rejected.
    /// First-configuration ordering determines product display ordering.
    public func configure(productIDs: [String]) {
        var seen = Set<String>()
        let ids = productIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ids.isEmpty else {
            lastError = SubscriptionError.notConfigured.localizedDescription
            return
        }
        if !self.productIDs.isEmpty {
            if Set(ids) != Set(self.productIDs) {
                lastError = "ZSubLayer has already been configured with different product IDs."
            }
            return
        }
        self.productIDs = ids
        Task { [weak self] in try? await self?.start() }
    }

    /// All waiters observe readiness published inside the same startup task.
    public func start() async throws {
        guard !productIDs.isEmpty else { throw record(SubscriptionError.notConfigured) }
        if isReady { return }
        if let startTask {
            await startTask.value
            return
        }
        beginOperation()
        let ids = productIDs
        let task = Task { [self] in
            defer { endOperation() }
            lastError = nil
            await adapter.start(productIDs: ids)
            // Metadata can fail offline. Signed local transactions still establish finite access.
            do { products = try await adapter.fetchProducts(productIDs: ids) }
            catch { lastError = error.localizedDescription }
            await reconcileEntitlements()
            isReady = true
        }
        startTask = task
        await task.value
    }

    public func purchase() async throws -> PurchaseResult {
        guard !productIDs.isEmpty else { throw record(SubscriptionError.notConfigured) }
        guard productIDs.count == 1, let id = productIDs.first else {
            throw record(SubscriptionError.multipleProductsRequireID)
        }
        return try await purchase(id)
    }

    public func purchase(_ productID: String) async throws -> PurchaseResult {
        guard !productIDs.isEmpty else { throw record(SubscriptionError.notConfigured) }
        guard productIDs.contains(productID) else { throw record(SubscriptionError.invalidProductID(productID)) }
        try Task.checkCancellation()
        try await start()
        try Task.checkCancellation()
        if let purchase = purchases[productID] { return try await purchase.value }
        let task = Task { [self] in
            try await performOperation {
                if !self.products.contains(where: { $0.id == productID }) {
                    self.products = try await self.adapter.fetchProducts(productIDs: self.productIDs)
                }
                guard self.products.contains(where: { $0.id == productID }) else {
                    throw SubscriptionError.productUnavailable(productID)
                }
                let result = try await self.adapter.purchase(productID: productID)
                if case .purchased = result { await self.reconcileEntitlements() }
                return result
            }
        }
        purchases[productID] = task
        defer { purchases[productID] = nil }
        return try await task.value
    }

    /// Uses AppStore.sync; errors reach both the caller and lastError.
    public func restore() async throws {
        try await start()
        try await performOperation {
            try await self.adapter.restore()
            await self.reconcileEntitlements()
        }
    }

    /// Coalesces concurrent refreshes and repeats if an update arrived during a suspended read.
    public func refresh() async throws {
        try await start()
        if let refreshTask {
            let result = await refreshTask.result
            if reconciledGeneration != changeGeneration { return try await refresh() }
            return try result.get()
        }
        let task = Task { [self] in
            defer { refreshTask = nil }
            try await performOperation {
                var metadataError: (any Error)?
                repeat {
                    let generation = self.changeGeneration
                    await self.reconcileEntitlements()
                    do {
                        self.products = try await self.adapter.fetchProducts(productIDs: self.productIDs)
                        metadataError = nil
                    } catch { metadataError = error }
                    if generation == self.changeGeneration { break }
                } while true
                if let metadataError { throw metadataError }
            }
        }
        refreshTask = task
        try await task.value
    }

    public func loadProducts() async throws {
        try await start()
        try await performOperation {
            self.products = try await self.adapter.fetchProducts(productIDs: self.productIDs)
        }
    }

    public func manageSubscriptions() async throws {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw record(SubscriptionError.noActiveWindow)
        }
        do { try await AppStore.showManageSubscriptions(in: scene) }
        catch { lastError = error.localizedDescription; throw error }
    }

    private func reconcileEntitlements() async {
        let generation = changeGeneration
        entitlements = await adapter.entitlements(productIDs: productIDs)
            .filter { productIDs.contains($0.productID) }
        reconciledGeneration = generation
        revalidateEntitlements()
    }

    /// Local expiry also runs without network access or another StoreKit event.
    func revalidateEntitlements() {
        let snapshot = AccessSnapshot.evaluate(entitlements, at: now())
        activeEntitlements = snapshot.ids
        subscriptionStatus = snapshot.status
        expiryTask?.cancel()
        guard let deadline = snapshot.nextExpirationDate else { return }
        let seconds = min(max(deadline.timeIntervalSince(now()), 0.01), 86_400)
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            self?.storeDidChange()
        }
    }

    private func storeDidChange() {
        guard !productIDs.isEmpty else { return }
        changeGeneration &+= 1
        revalidateEntitlements()
        Task { [weak self] in try? await self?.refresh() }
    }

    /// MainActor alone doesn't serialize across await; chain complete store operations explicitly.
    private func performOperation<T: Sendable>(
        _ operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let previous = operationTail
        beginOperation()
        let task = Task { @MainActor [self] in
            await previous?.value
            lastError = nil
            do { return try await operation() }
            catch { lastError = error.localizedDescription; throw error }
        }
        operationTail = Task { _ = try? await task.value }
        defer { endOperation() }
        return try await task.value
    }

    private func beginOperation() { pendingOperations += 1; isLoading = true }
    private func endOperation() { pendingOperations -= 1; isLoading = pendingOperations > 0 }
    private func record(_ error: SubscriptionError) -> SubscriptionError {
        lastError = error.localizedDescription
        return error
    }
}
