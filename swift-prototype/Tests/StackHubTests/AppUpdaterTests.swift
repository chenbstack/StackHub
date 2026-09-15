import Sparkle
import XCTest
@testable import StackHub

final class AppUpdaterTests: XCTestCase {
    @MainActor
    func testBackgroundOfferOnlyShowsButtonAndDoesNotAuthorizeRestart() async {
        let driver = UpdateUserDriver()
        XCTAssertFalse(driver.isVisible)
        XCTAssertEqual(driver.offerUpdate(version: "1.0.3"), .dismiss)
        driver.dismissUpdateInstallation()
        XCTAssertEqual(driver.availableVersion, "1.0.3")
        XCTAssertTrue(driver.isVisible)
        XCTAssertFalse(driver.isBusy)
        XCTAssertNil(driver.failure)
        let choice = await driver.showReadyToInstallAndRelaunch()
        XCTAssertEqual(choice, .dismiss)
        XCTAssertEqual(driver.offerUpdate(version: "1.0.4"), .dismiss)
        XCTAssertEqual(driver.availableVersion, "1.0.4")
    }

    @MainActor
    func testOneClickAuthorizesDownloadAndRelaunchWithoutSecondPrompt() async {
        let driver = UpdateUserDriver()
        XCTAssertFalse(driver.beginInstallation())
        _ = driver.offerUpdate(version: "1.0.3")
        XCTAssertTrue(driver.beginInstallation())
        XCTAssertFalse(driver.beginInstallation())
        XCTAssertEqual(driver.offerUpdate(version: "1.0.3"), .install)
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 25)
        XCTAssertEqual(driver.progress, 0.25)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(0.7)
        XCTAssertEqual(driver.phase, .extracting)
        let choice = await driver.showReadyToInstallAndRelaunch()
        XCTAssertEqual(choice, .install)
        XCTAssertEqual(driver.phase, .installing)
    }

    @MainActor
    func testFailureKeepsVersionRetryableAndRevokesRestartAuthorization() async {
        let driver = UpdateUserDriver()
        _ = driver.offerUpdate(version: "1.0.3")
        XCTAssertTrue(driver.beginInstallation())
        await driver.showUpdaterError(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Network failed"]))
        driver.dismissUpdateInstallation()
        XCTAssertEqual(driver.failure?.message, "Network failed")
        XCTAssertTrue(driver.isVisible)
        XCTAssertFalse(driver.isBusy)
        let choice = await driver.showReadyToInstallAndRelaunch()
        XCTAssertEqual(choice, .dismiss)
        XCTAssertTrue(driver.beginInstallation())
        XCTAssertNil(driver.failure)
    }

    @MainActor
    func testBackgroundErrorsAreSilentAndNoUpdateRemovesButton() async {
        let driver = UpdateUserDriver()
        await driver.showUpdaterError(NSError(domain: "test", code: 1))
        driver.dismissUpdateInstallation()
        XCTAssertNil(driver.failure)
        XCTAssertFalse(driver.isVisible)
        _ = driver.offerUpdate(version: "1.0.3")
        driver.clearAvailableUpdate()
        XCTAssertFalse(driver.isVisible)
    }

    @MainActor
    func testInformationOnlyUpdateCannotBeInstalled() async {
        let driver = UpdateUserDriver()
        XCTAssertEqual(driver.offerUpdate(version: "1.0.3", informationOnly: true), .dismiss)
        XCTAssertFalse(driver.isVisible)
        XCTAssertFalse(driver.beginInstallation())
    }

    @MainActor
    func testProgressHandlesUnknownAndIncorrectContentLengths() async {
        let driver = UpdateUserDriver()
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(0)
        driver.showDownloadDidReceiveData(ofLength: 10)
        XCTAssertNil(driver.progress)
        driver.showDownloadDidReceiveExpectedContentLength(5)
        XCTAssertEqual(driver.progress, 1)
        driver.showDownloadDidReceiveData(ofLength: .max)
        XCTAssertEqual(driver.progress, 1)
        driver.showExtractionReceivedProgress(.nan)
        XCTAssertNil(driver.progress)
    }

    func testPackagedUpdaterChecksHourlyWithoutDownloadingOrPrompting() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: package.appendingPathComponent("Packaging/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 3600)
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUSendProfileInfo"] as? Bool, false)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUFeedURL"] as? String, "https://github.com/chenbstack/StackHub/releases/latest/download/appcast.xml")
        let publicKey = try XCTUnwrap(info["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
    }
}
