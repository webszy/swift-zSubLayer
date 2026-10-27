import Foundation

/// Display-only metadata. The application does not need to import StoreKit.
public struct SubscriptionProduct: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let productDescription: String
    public let displayPrice: String
    public let period: SubscriptionPeriod?

    public init(
        id: String,
        displayName: String,
        productDescription: String,
        displayPrice: String,
        period: SubscriptionPeriod?
    ) {
        self.id = id
        self.displayName = displayName
        self.productDescription = productDescription
        self.displayPrice = displayPrice
        self.period = period
    }
}

public struct SubscriptionPeriod: Equatable, Sendable {
    public enum Unit: String, Equatable, Sendable {
        case day, week, month, year
    }

    public let value: Int
    public let unit: Unit

    public init(value: Int, unit: Unit) {
        self.value = value
        self.unit = unit
    }
}
