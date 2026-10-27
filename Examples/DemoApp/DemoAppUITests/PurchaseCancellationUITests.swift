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
        XCTAssertEqual(app.staticTexts["premiumState"].label, "isPremium: false")
        purchase.tap()

        let cancelLabel = NSPredicate(format: "label == 'Cancel' OR label == '取消' OR label == 'Close' OR label == '关闭'")
        let cancel = app.buttons.matching(cancelLabel).firstMatch
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemCancel = springboard.buttons.matching(cancelLabel).firstMatch
        let storeUI = XCUIApplication(bundleIdentifier: "com.apple.StoreKitUIService")
        let storeCancel = storeUI.buttons.matching(cancelLabel).firstMatch
        if cancel.waitForExistence(timeout: 10) {
            cancel.tap()
        } else if systemCancel.waitForExistence(timeout: 3) {
            systemCancel.tap()
        } else if storeCancel.waitForExistence(timeout: 3) {
            storeCancel.tap()
        } else {
            for attachment in [XCTAttachment(string: app.debugDescription),
                               XCTAttachment(screenshot: app.screenshot()),
                               XCTAttachment(string: springboard.debugDescription)] {
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTFail("Local StoreKit confirmation must appear")
        }

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
