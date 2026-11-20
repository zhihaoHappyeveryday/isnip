import Foundation
import XCTest
@testable import AirSnipApp

final class UpdateCheckerTests: XCTestCase {
    func testServiceUnavailableReportsFailure() async {
        guard case .failure = await checkLatest(status: 503) else {
            return XCTFail("An unavailable release endpoint should report a failed check")
        }
    }

    func testMissingForkReleaseHasItsOwnStatus() async {
        guard case .success(.noPublishedRelease) = await checkLatest(status: 404) else {
            return XCTFail("A fork without a published release should report that status")
        }
    }

    func testSameOrOlderReleaseIsUpToDate() async {
        for version in ["0.4.0", "0.3.19"] {
            let result = await checkLatest(status: 200, body: release(version: version))
            guard case .success(.upToDate) = result else {
                XCTFail("Version \(version) should leave the app up to date")
                continue
            }
        }
    }

    func testNewerReleaseUsesTheMatchingForkDMG() async throws {
        let base = "https://github.com/zhihaoHappyeveryday/isnip/releases/download/v99.0.0/"
        let arm = "isnip-macos-arm64-v99.0.0.dmg"
        let intel = "isnip-macos-amd64-v99.0.0.dmg"
        let assets = [arm, intel, "isnip-macos-arm64-v99.0.0.zip"].map {
            ["name": $0, "browser_download_url": base + $0]
        }
        let result = try await checkLatest(status: 200, body: release(version: "99.0.0", assets: assets)).get()
        guard case .available(let info) = result else { return XCTFail("Expected a newer release") }
        #if arch(x86_64)
        let expected = intel
        #else
        let expected = arm
        #endif
        XCTAssertEqual(info.version, "99.0.0")
        XCTAssertEqual(info.downloadURL?.absoluteString, base + expected)
    }

    func testReleasePageIsAvailableWithoutDMG() async throws {
        let result = try await checkLatest(status: 200, body: release(version: "99.0.0")).get()
        guard case .available(let info) = result else { return XCTFail("Expected a newer release") }
        XCTAssertNil(info.downloadURL)
        XCTAssertEqual(info.htmlURL.absoluteString, "https://github.com/zhihaoHappyeveryday/isnip/releases/tag/v99.0.0")
    }

    func testReleasePageMustBelongToTheFork() async {
        var body = release(version: "99.0.0")
        body["html_url"] = "https://github.com/zzusec/isnip/releases/tag/v99.0.0"
        guard case .failure = await checkLatest(status: 200, body: body) else {
            return XCTFail("The fork updater should reject a release page in the upstream repository")
        }
    }

    func testUpstreamDMGIsIgnored() async throws {
        let base = "https://github.com/zzusec/isnip/releases/download/v99.0.0/"
        let assets = ["isnip-macos-arm64-v99.0.0.dmg", "isnip-macos-amd64-v99.0.0.dmg"].map {
            ["name": $0, "browser_download_url": base + $0]
        }
        let result = try await checkLatest(status: 200, body: release(version: "99.0.0", assets: assets)).get()
        guard case .available(let info) = result else { return XCTFail("Expected the fork release page to remain available") }
        XCTAssertNil(info.downloadURL)
        XCTAssertEqual(info.htmlURL.absoluteString, "https://github.com/zhihaoHappyeveryday/isnip/releases/tag/v99.0.0")
    }

    func testMalformedReleaseReportsFailure() async {
        for body in [[:], release(version: "invalid")] {
            guard case .failure = await checkLatest(status: 200, body: body) else {
                XCTFail("Malformed release metadata should report a failed check")
                continue
            }
        }
    }

    func testNetworkErrorReportsFailure() async {
        let result = await UpdateChecker.checkLatest { _ in
            throw URLError(.notConnectedToInternet)
        }
        guard case .failure(let error as URLError) = result else { return XCTFail("Expected a network error") }
        XCTAssertEqual(error.code, .notConnectedToInternet)
    }

    @MainActor
    func testAutomaticUpdateUsesTheCurrentSwitchAndSkippedVersion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AirSnipAppController(configURL: directory.appendingPathComponent("config.json"))
        let mockCheck = { await self.checkLatest(status: 200, body: self.release(version: "99.0.0")) }

        app.updateConfig { $0.autoCheckUpdate = false }
        let disabled = await app.automaticUpdate {
            XCTFail("Automatic update must not contact the server when disabled")
            return await mockCheck()
        }
        XCTAssertNil(disabled)

        app.updateConfig {
            $0.autoCheckUpdate = true
            $0.skippedVersion = "99.0.0"
        }
        let skipped = await app.automaticUpdate(checkLatest: mockCheck)
        XCTAssertNil(skipped)

        app.updateConfig { $0.skippedVersion = nil }
        let available = await app.automaticUpdate(checkLatest: mockCheck)
        XCTAssertEqual(available?.version, "99.0.0")
    }

    private func checkLatest(status: Int, body: [String: Any] = [:]) async -> Result<UpdateChecker.Status, Error> {
        await UpdateChecker.checkLatest(installedVersion: "0.4.0") { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.absoluteString, "https://api.github.com/repos/zhihaoHappyeveryday/isnip/releases/latest")
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            return (try JSONSerialization.data(withJSONObject: body), response)
        }
    }

    private func release(version: String, assets: [[String: String]] = []) -> [String: Any] {
        [
            "tag_name": "v\(version)",
            "html_url": "https://github.com/zhihaoHappyeveryday/isnip/releases/tag/v\(version)",
            "assets": assets,
        ]
    }
}
