import AppKit
import XCTest
@testable import AirSnipApp

final class ClosedPinHistoryTests: XCTestCase {
    @MainActor
    func testTimestampedFilesAndLegacyPinsRestoreTogether() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("isnip-history-test-\(UUID())")
        let day = root.appendingPathComponent("2026-11-21", isDirectory: true)
        try fileManager.createDirectory(at: day, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.json")
        let legacy = try makeSnapshot(width: 24, text: "legacy text")
        let legacyName = try saveLegacyPin(legacy, in: day, configURL: configURL)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let closedAt = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 21, hour: 19, minute: 3, second: 6
        )))
        let baseName = "isnip-20261121-190306"
        let existingText = day.appendingPathComponent("\(baseName)-3.txt")
        try "keep this file".write(to: existingText, atomically: true, encoding: .utf8)

        let first = try makeSnapshot(width: 32)
        let second = try makeSnapshot(width: 40, text: "new text")
        let third = try makeSnapshot(width: 48)
        let history = ClosedPinHistory(configURL: configURL)
        history.remember([first, second], historyRoot: root, closedAt: closedAt)
        history.remember([third], historyRoot: root, closedAt: closedAt)
        await withCheckedContinuation { done in
            history.finishPendingWrites { done.resume() }
        }

        XCTAssertEqual(Set(try fileManager.contentsOfDirectory(atPath: day.path)), [
            "\(legacyName).png", "\(legacyName).txt",
            "\(baseName).png", "\(baseName)-2.png", "\(baseName)-2.txt",
            existingText.lastPathComponent, "\(baseName)-4.png"
        ])

        let restarted = ClosedPinHistory(configURL: configURL)
        for expected in [third, second, first, legacy] {
            let restored = await restoreLast(from: restarted)
            let snapshot = try XCTUnwrap(restored)
            XCTAssertEqual(snapshot.image.width, expected.image.width)
            XCTAssertEqual(snapshot.originalText, expected.originalText)
        }
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: day.path), [existingText.lastPathComponent])
        XCTAssertEqual(try String(contentsOf: existingText, encoding: .utf8), "keep this file")
    }

    private func saveLegacyPin(_ snapshot: PinSnapshot, in day: URL, configURL: URL) throws -> String {
        let id = UUID()
        let baseName = "pin-\(id.uuidString)"
        let bitmap = NSBitmapImageRep(cgImage: snapshot.image)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: day.appendingPathComponent("\(baseName).png"))
        let text = try XCTUnwrap(snapshot.originalText)
        try text.write(to: day.appendingPathComponent("\(baseName).txt"), atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        let manifest: [String: Any] = [
            "records": [[
                "files": [
                    "dayDirectory": try JSONSerialization.jsonObject(with: encoder.encode(day), options: .fragmentsAllowed),
                    "id": id.uuidString,
                    "hasOriginalText": true
                ],
                "displayState": try JSONSerialization.jsonObject(with: encoder.encode(snapshot.displayState))
            ]],
            "filesToRemove": []
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: ClosedPinHistory.manifestURL(for: configURL))
        return baseName
    }

    private func makeSnapshot(width: Int, text: String? = nil) throws -> PinSnapshot {
        let height = 16
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let size = CGSize(width: width, height: height)
        let state = PinDisplayState(
            frame: CGRect(origin: .zero, size: size), baseSize: size,
            backingScale: 1, zoomScale: 1, preferredOpacity: 1, effectiveWindowOpacity: 1,
            showBorder: true, isClickThrough: false
        )
        return PinSnapshot(image: image, originalText: text, displayState: state)
    }

    @MainActor
    private func restoreLast(from history: ClosedPinHistory) async -> PinSnapshot? {
        await withCheckedContinuation { done in
            var snapshot: PinSnapshot?
            history.restoreLast(if: { $0 }, accept: { pin in
                snapshot = pin
                return true
            }, completion: { restored, skippedUnreadable in
                XCTAssertTrue(restored)
                XCTAssertFalse(skippedUnreadable)
                done.resume(returning: snapshot)
            })
        }
    }
}
