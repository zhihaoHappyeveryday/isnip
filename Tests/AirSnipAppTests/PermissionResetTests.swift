import XCTest
@testable import AirSnipApp

final class PermissionResetTests: XCTestCase {
    @MainActor
    func testResetBothRelaunchesOnceForScreenRecording() async {
        XCTAssertEqual(recordActions(.screenRecordingAndAccessibility), [
            ["reset", "ScreenCapture"],
            ["reset", "Accessibility"],
            ["relaunch", "--request-screen-capture"],
        ])
    }

    @MainActor
    func testResetAccessibilityLeavesScreenRecordingAlone() async {
        XCTAssertEqual(recordActions(.accessibility), [
            ["reset", "Accessibility"],
            ["relaunch", "--request-accessibility"],
        ])
    }

    @MainActor
    func testPartialFailureRelaunchesForThePermissionThatWasReset() async {
        XCTAssertEqual(recordActions(.screenRecordingAndAccessibility, failing: ["ScreenCapture"]), [
            ["reset", "ScreenCapture"],
            ["reset", "Accessibility"],
            ["relaunch", "--request-accessibility"],
        ])
        XCTAssertEqual(recordActions(.screenRecordingAndAccessibility, failing: ["Accessibility"]), [
            ["reset", "ScreenCapture"],
            ["reset", "Accessibility"],
            ["relaunch", "--request-screen-capture"],
        ])
    }

    @MainActor
    func testFailedResetsDoNotRelaunch() async {
        XCTAssertEqual(recordActions(.screenRecordingAndAccessibility, failing: ["ScreenCapture", "Accessibility"]), [
            ["reset", "ScreenCapture"],
            ["reset", "Accessibility"],
        ])
    }

    @MainActor
    private func recordActions(_ scope: PermissionReset, failing: Set<String> = []) -> [[String]] {
        var actions: [[String]] = []
        scope.resetAndRelaunch(reset: { permission in
            actions.append(["reset", permission])
            return !failing.contains(permission)
        }, relaunch: { arguments in
            actions.append(["relaunch"] + arguments)
        })
        return actions
    }
}
