import SwiftUI
import ZSubLayer

@main
@MainActor
struct DemoApp: App {
    init() {
        if ProcessInfo.processInfo.environment["ZSUBLAYER_TESTING"] != "1" {
            SubscriptionManager.shared.configure(productIDs: [
                "com.example.zsublayer.monthly", "com.example.zsublayer.yearly"
            ])
        }
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["ZSUBLAYER_TESTING"] == "1" {
                // Tests install SKTestSession before constructing the SDK singleton.
                Text("Running local subscription tests")
            } else {
                SubscriptionScreen()
            }
        }
    }
}

@MainActor
private struct SubscriptionScreen: View {
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @State private var outcome = "No purchase yet"
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            List {
                Section("Membership") {
                    Text("isPremium: \(subscriptions.isPremium.description)")
                        .accessibilityIdentifier("premiumState")
                    Text("Status: \(String(describing: subscriptions.subscriptionStatus))")
                        .accessibilityIdentifier("subscriptionStatus")
                    Text(subscriptions.isReady ? "Ready" : "Checking subscriptions…")
                    if subscriptions.isLoading { ProgressView() }
                }
                Section("Subscriptions") {
                    ForEach(subscriptions.products) { product in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(product.displayName).font(.headline)
                            Text(product.productDescription)
                            Text(product.displayPrice)
                            Button("Purchase") {
                                Task {
                                    do {
                                        let result = try await subscriptions.purchase(product.id)
                                        outcome = String(describing: result)
                                        errorMessage = nil
                                    } catch { errorMessage = error.localizedDescription }
                                }
                            }
                            .accessibilityIdentifier("purchase.\(product.id)")
                            .disabled(subscriptions.isLoading)
                        }
                    }
                }
                Section {
                    Button("Restore Purchases") {
                        Task {
                            do {
                                try await subscriptions.restore()
                                outcome = "Restore completed"
                                errorMessage = nil
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .accessibilityIdentifier("restorePurchases")
                    .disabled(subscriptions.isLoading)
                    Button("Refresh") {
                        Task {
                            do { try await subscriptions.refresh(); errorMessage = nil }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(subscriptions.isLoading)
                }
                Section("Last result") {
                    Text(outcome)
                        .accessibilityIdentifier("purchaseResult")
                    Text(errorMessage ?? subscriptions.lastError ?? "No error")
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("lastError")
                }
            }
            .navigationTitle("ZSubLayer Demo")
        }
        .navigationViewStyle(.stack)
    }
}
