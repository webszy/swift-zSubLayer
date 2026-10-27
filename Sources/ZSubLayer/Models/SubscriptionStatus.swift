import Foundation

/// Billing lifecycle state; it must NOT be treated as a verified entitlement.
/// Billing retry alone does not grant access; verified grace has its own finite deadline.
public enum SubscriptionStatus: Equatable, Sendable {
    case unknown
    case inactive
    case active(expirationDate: Date?)
    case gracePeriod(expirationDate: Date?)
    case billingRetry
    case expired
    case revoked
}
