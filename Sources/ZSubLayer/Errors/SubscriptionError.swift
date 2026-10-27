import Foundation

/// Errors exposed by ZSubLayer; no vendor SDK types leak to applications.
public enum SubscriptionError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidProductID(String)
    case multipleProductsRequireID
    case productUnavailable(String)
    case purchaseFailed(String)
    case verificationFailed
    case storeUnavailable
    case noActiveWindow

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Configure ZSubLayer with at least one product ID before purchasing."
        case .invalidProductID(let id):
            return "The product ID is not configured: \(id)."
        case .multipleProductsRequireID:
            return "Multiple products are configured. Use purchase(\"your.product.id\")."
        case .productUnavailable(let id):
            return "The App Store product is unavailable: \(id)."
        case .purchaseFailed(let message):
            return "The purchase failed: \(message)"
        case .verificationFailed:
            return "The App Store transaction could not be verified."
        case .storeUnavailable:
            return "The App Store is currently unavailable."
        case .noActiveWindow:
            return "No active application window is available for subscription management."
        }
    }
}
