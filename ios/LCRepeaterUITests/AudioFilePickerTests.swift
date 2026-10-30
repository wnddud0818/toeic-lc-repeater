import XCTest

final class AudioFilePickerTests: XCTestCase {
    @MainActor
    func testMP3SelectionClosesPickerAndDecodesAudio() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--smoke-audio-picker", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["picker-smoke.open"].tap()
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "토익 회귀")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(file.isEnabled)
        // Tap the file icon; the middle of an icon-mode cell is its filename.
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        // Some OS versions require Open after selecting a file, others import immediately.
        let open = app.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "열기"])).firstMatch
        if open.waitForExistence(timeout: 2), open.isHittable { open.tap() }
        let imported = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "가져오기 확인:")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(imported.label.contains("토익 회귀"))
        XCTAssertTrue(app.buttons["picker-smoke.open"].isHittable)
    }

    @MainActor
    func testCancelReturnsWithoutStartingConversion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--smoke-audio-picker", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.buttons["picker-smoke.open"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "취소"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(app.buttons["picker-smoke.open"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["picker-smoke.result"].label, "선택 전")
    }
}
