import StoreKitTest
import XCTest

/// Swift Testing covers unit/integration logic; XCTest is required for XCUITest UI automation.
@MainActor
final class PurchaseCancellationUITests: XCTestCase {
    func testCancellingLocalConfirmationDoesNotUnlock() throws {
        continueAfterFailure = false
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Subscriptions", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = false
        defer { session.clearTransactions(); session.resetToDefaultState() }

        let app = XCUIApplication()
        app.launchEnvironment["ZSUBLAYER_TESTING"] = "0"
        app.launch()
        let purchase = app.buttons["purchase.com.example.zsublayer.monthly"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 15))
        let purchaseReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in purchase.isEnabled && purchase.isHittable },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [purchaseReady], timeout: 60), .completed,
                       "Purchase must be enabled and hittable before tapping")
        XCTAssertEqual(app.staticTexts["premiumState"].label, "isPremium: false")
        purchase.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let storeUI = XCUIApplication(bundleIdentifier: "com.apple.StoreKitUIService")
        // The CI hierarchy exposes identifier "dismiss", label "close" in SpringBoard.
        // Scope cancellation to the Xcode sheet so an Apple Account alert cannot pass.
        let cancelLabel = NSPredicate(format: "identifier == 'dismiss' OR label ==[c] 'Cancel' OR label ==[c] 'Close' OR label == '取消' OR label == '关闭'")
        let controls = [app, springboard, storeUI].map {
            $0.navigationBars["Xcode"].buttons.matching(cancelLabel).firstMatch
        }
        let confirmation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in controls.contains { $0.exists && $0.isHittable } },
            object: nil
        )
        // Hosted CI can deliver the native sheet at the previous 20-second deadline.
        guard XCTWaiter.wait(for: [confirmation], timeout: 60) == .completed,
              let cancel = controls.first(where: { $0.exists && $0.isHittable }) else {
            for attachment in [XCTAttachment(string: app.debugDescription),
                               XCTAttachment(screenshot: app.screenshot()),
                               XCTAttachment(string: springboard.debugDescription),
                               XCTAttachment(string: storeUI.debugDescription)] {
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTFail("Local StoreKit confirmation must appear")
            return
        }
        cancel.tap()

        let result = app.staticTexts["purchaseResult"]
        if !result.isHittable { app.swipeUp() }
        let cancelled = NSPredicate(format: "label == 'cancelled'")
        expectation(for: cancelled, evaluatedWith: result)
        waitForExpectations(timeout: 10)
        app.swipeDown()
        XCTAssertEqual(app.staticTexts["premiumState"].label, "isPremium: false")
        XCTAssertTrue(session.allTransactions().isEmpty)
    }
}
