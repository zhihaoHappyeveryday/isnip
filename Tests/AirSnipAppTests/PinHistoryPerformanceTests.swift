import AppKit
import XCTest
import AirSnipCore
@testable import AirSnipApp

final class PinHistoryPerformanceTests: XCTestCase {
    @MainActor
    func testF3ReturnsBeforeReadingSavedPinsAndKeepsRequestOrder() async throws {
        try await withHistory([48, 64, 80]) { app, pasteboard in
            app.triggerPinOrRestore()
            XCTAssertEqual(app.pinManager.count, 0, "The hotkey must return before reading saved history")
            app.triggerPinOrRestore()
            pasteboard.setString("new clipboard text", forType: .string)
            app.triggerPinOrRestore()
            pasteboard.clearContents()
            await withCheckedContinuation { done in
                app.triggerPinOrRestore(completion: { done.resume() })
            }
            XCTAssertEqual(app.pinManager.windows.count, 4)
            XCTAssertEqual(app.pinManager.windows.filter { $0.originalText == nil }.map { $0.cgImage.width }, [80, 64, 48])
            XCTAssertEqual(app.pinManager.windows.dropFirst(2).first?.originalText, "new clipboard text")
        }
    }

    @MainActor
    func testQuitKeepsAnUndisplayedRestoreInHistory() async throws {
        try await withHistory([48]) { app, pasteboard in
            try self.openPin(width: 64, in: app)
            app.triggerPinOrRestore()
            await withCheckedContinuation { done in
                app.pinManager.saveOpenPinsOnQuit { done.resume() }
            }
            XCTAssertTrue(app.pinManager.windows.isEmpty)

            let restarted = AirSnipAppController(configURL: app.configURL, pinPasteboard: pasteboard)
            defer { self.hidePins(in: restarted) }
            restarted.triggerPinOrRestore()
            await withCheckedContinuation { done in
                restarted.triggerPinOrRestore(completion: { done.resume() })
            }
            XCTAssertEqual(restarted.pinManager.windows.map { $0.cgImage.width }, [64, 48])
        }
    }

    @MainActor
    func testClosingAfterReenablingHistoryUsesTheNewLimit() async throws {
        try await withHistory([]) { app, _ in
            app.updateConfig { $0.pinHistoryLimit = 0 }
            app.updateConfig { $0.pinHistoryLimit = 5 }
            try self.openPin(width: 64, in: app)
            app.pinManager.closeAll()
            await withCheckedContinuation { done in
                app.triggerPinOrRestore(completion: { done.resume() })
            }
            XCTAssertEqual(app.pinManager.windows.map { $0.cgImage.width }, [64])
        }
    }

    @MainActor
    private func withHistory(
        _ widths: [Int],
        _ test: (AirSnipAppController, NSPasteboard) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isnip-history-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        let pasteboard = NSPasteboard.withUniqueName()
        defer {
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }

        var config = AirSnipConfig()
        config.lastSaveDirectory = directory.path
        try config.save(to: configURL)
        let seed = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        for width in widths { try openPin(width: width, in: seed) }
        seed.pinManager.closeAll()
        await withCheckedContinuation { done in
            seed.pinManager.finishHistoryWrites { done.resume() }
        }
        seed.settingsController = nil

        let app = AirSnipAppController(configURL: configURL, pinPasteboard: pasteboard)
        defer { hidePins(in: app) }
        try await test(app, pasteboard)
    }

    @MainActor
    private func openPin(width: Int, in app: AirSnipAppController) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertTrue(app.pinManager.createPin(
            cgImage: image, backingScale: 1, preferredScreenOriginAppKit: nil, config: app.config
        ))
    }

    @MainActor
    private func hidePins(in app: AirSnipAppController) {
        for pin in app.pinManager.windows { pin.window.orderOut(nil) }
        app.settingsController = nil
    }
}
