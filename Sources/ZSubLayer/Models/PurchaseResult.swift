/// Cancellation and pending approval are valid App Store outcomes, not failures.
public enum PurchaseResult: Equatable, Sendable {
    case purchased(productID: String)
    case pending
    case cancelled
}
