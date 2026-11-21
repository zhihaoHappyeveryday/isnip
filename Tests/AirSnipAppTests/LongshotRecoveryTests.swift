import AppKit
import XCTest
import AirSnipCore
@testable import AirSnipApp

final class LongshotRecoveryTests: XCTestCase {
    @MainActor
    func testAutoScrollCanRestartFromThePreviewWhenTheOriginalStartDoesNotMatch() async throws {
        let page = ScrollingPage()
        var scrolls: [Int] = []
        let controller = try makeController(page, autoStart: true, scroll: { points in
            scrolls.append(points)
            page.scroll(points)
        }) {
            page.frame
        }
        defer { controller.stopAndCleanup() }
        page.top = 200
        let newStart = page.frame
        controller.start()

        try await waitUntil { !controller.isAutoScrolling }
        XCTAssertTrue(scrolls.isEmpty)
        XCTAssertEqual(controller.segmentCount, 0)
        let restartHint = "Cannot confirm the start. You can start from the preview."
        XCTAssertEqual(controller.statusHint, restartHint)
        guard controller.statusHint == restartHint else { return }
        XCTAssertTrue(controller.thumbnailImage.flatMap(PixelBufferRGBA.init(cgImage:)) == newStart, "Unexpected start preview")

        controller.toggleAutoScroll()
        try await waitUntil { controller.segmentCount > 0 }
        var output: PixelBufferRGBA?
        controller.onFinishCopy = { image, _ in output = PixelBufferRGBA(cgImage: image) }
        controller.finishAndCopy()
        try await waitUntil { output != nil }
        let exported = try XCTUnwrap(output)
        XCTAssertEqual(
            exported.cropped(to: PixelRect(x: 0, y: 0, width: newStart.width, height: newStart.height)),
            newStart
        )
    }

    @MainActor
    func testChangingThePageWhileTheStartPreviewIsShowingRequiresASecondConfirmation() async throws {
        let page = ScrollingPage()
        var scrolls: [Int] = []
        let controller = try makeController(page, autoStart: true, scroll: { points in
            scrolls.append(points)
        }) {
            page.frame
        }
        defer { controller.stopAndCleanup() }
        page.top = 200
        controller.start()
        try await waitUntil { !controller.isAutoScrolling }

        page.top = 20
        let changedFrame = page.frame
        controller.toggleAutoScroll()
        try await waitUntil { !controller.isAutoScrolling }

        XCTAssertTrue(scrolls.isEmpty)
        XCTAssertEqual(controller.segmentCount, 0)
        XCTAssertEqual(controller.statusHint, "Cannot confirm the start. You can start from the preview.")
        XCTAssertTrue(controller.thumbnailImage.flatMap(PixelBufferRGBA.init(cgImage:)) == changedFrame, "Unexpected start preview")
    }

    @MainActor
    func testSameVerifiedStartPositionCanRefreshTheFirstScreen() async throws {
        let page = ScrollingPage()
        let controller = try makeController(page, autoStart: true, scrollPosition: { page.position }) { page.frame }
        defer { controller.stopAndCleanup() }
        page.repaintedRows = 0..<4
        let repaintedStart = page.frame
        controller.start()
        try await waitUntil { controller.segmentCount > 0 }

        var output: PixelBufferRGBA?
        controller.onFinishCopy = { image, _ in output = PixelBufferRGBA(cgImage: image) }
        controller.finishAndCopy()
        try await waitUntil { output != nil }
        XCTAssertEqual(output?.cropped(to: PixelRect(x: 0, y: 0, width: page.width, height: page.frameHeight)), repaintedStart)
    }

    @MainActor
    func testReplacingThePageAtTheSameScrollbarPositionRequiresConfirmation() async throws {
        let page = ScrollingPage()
        var moves: [Int] = []
        let controller = try makeController(page, autoStart: true, scroll: { points in
            moves.append(points)
            page.scroll(points)
        }, scrollPosition: { page.position }) { page.frame }
        defer { controller.stopAndCleanup() }
        page.repaintedRows = 0..<page.frameHeight
        controller.start()
        try await waitUntil { controller.canRestartFromPreview && !controller.isAutoScrolling }
        XCTAssertTrue(moves.isEmpty)

        page.repaintedRows = 0..<0
        controller.toggleAutoScroll()
        try await waitUntil { !controller.isAutoScrolling }
        XCTAssertTrue(moves.isEmpty)
        XCTAssertEqual(controller.thumbnailImage.flatMap(PixelBufferRGBA.init(cgImage:)), page.frame)
        controller.toggleAutoScroll()
        try await waitUntil { controller.segmentCount > 0 }
    }

    @MainActor
    func testPauseAndOutputCancelInFlightConfirmationAndKeepTheRestartPrompt() async throws {
        let page = ScrollingPage()
        var scrolls: [Int] = []
        var holdFrame = false
        var releaseCapture: CheckedContinuation<Void, Never>?
        let controller = try makeController(page, autoStart: true, scroll: { points in
            scrolls.append(points)
        }) {
            if holdFrame {
                await withCheckedContinuation { releaseCapture = $0 }
            }
            return page.frame
        }
        defer {
            controller.stopAndCleanup()
            releaseCapture?.resume()
        }
        page.top = 200
        controller.start()
        try await waitUntil { !controller.isAutoScrolling }
        let restartHint = controller.statusHint

        holdFrame = true
        controller.toggleAutoScroll()
        try await waitUntil { releaseCapture != nil }
        controller.toggleAutoScroll()
        XCTAssertEqual(controller.statusHint, restartHint)
        releaseCapture?.resume()
        releaseCapture = nil

        controller.toggleAutoScroll()
        try await waitUntil { releaseCapture != nil }
        var didCopy = false
        controller.onFinishCopy = { _, _ in didCopy = true }
        controller.finishAndCopy()
        XCTAssertFalse(controller.isAutoScrolling)
        releaseCapture?.resume()
        releaseCapture = nil
        holdFrame = false
        try await Task.sleep(for: .milliseconds(220))

        XCTAssertFalse(didCopy)
        XCTAssertTrue(scrolls.isEmpty)
        XCTAssertTrue(controller.statusHint.hasPrefix("No long screenshot yet"))
        XCTAssertTrue(controller.thumbnailImage.flatMap(PixelBufferRGBA.init(cgImage:)) == page.frame, "Unexpected start preview")
    }

    @MainActor
    func testIdenticalRepeatingViewNeedsConfirmationBeforeTheFirstAutomaticScroll() async throws {
        let page = ScrollingPage(repeatRows: 16)
        var scrolls: [Int] = []
        let controller = try makeController(page, autoStart: true, scroll: { points in
            scrolls.append(points)
            page.scroll(points)
        }) {
            page.frame
        }
        defer { controller.stopAndCleanup() }
        page.top = 16
        controller.start()
        try await waitUntil { !controller.isAutoScrolling }

        XCTAssertTrue(scrolls.isEmpty)
        let restartHint = "Cannot confirm the start. You can start from the preview."
        XCTAssertEqual(controller.statusHint, restartHint)
        guard controller.statusHint == restartHint else { return }

        controller.toggleAutoScroll()
        try await waitUntil { scrolls.contains { $0 > 0 } }
    }

    @MainActor
    func testStartupBacksOffAndStopsAfterFiveMissingFrames() async throws {
        let page = ScrollingPage()
        var captureTimes: [ContinuousClock.Instant] = []
        let controller = try makeController(page, autoStart: true) {
            captureTimes.append(.now)
            return nil
        }
        defer { controller.stopAndCleanup() }
        controller.start()
        try await waitUntil { !controller.isAutoScrolling }
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(page.top, 0)
        XCTAssertEqual(captureTimes.count, 5)
        XCTAssertEqual(controller.statusHint, "No screen captured. Click Auto-Scroll to retry.")
        let intervals = zip(captureTimes, captureTimes.dropFirst()).map { $0.duration(to: $1) }
        for (interval, minimum) in zip(intervals, [300, 500, 700, 900]) {
            XCTAssertGreaterThanOrEqual(interval, .milliseconds(minimum))
        }
    }

    @MainActor
    func testStartupTimesOutDuringCaptureAndCanRetryWithoutWaitingForTheLateFrame() async throws {
        let page = ScrollingPage()
        var releaseCapture: CheckedContinuation<Void, Never>?
        var captures = 0
        var scrolls: [Int] = []
        let controller = try makeController(page, autoStart: true, scroll: { points in
            scrolls.append(points)
            page.scroll(points)
        }) {
            captures += 1
            if captures == 1 {
                await withCheckedContinuation { releaseCapture = $0 }
            }
            return page.frame
        }
        defer {
            controller.stopAndCleanup()
            releaseCapture?.resume()
        }
        controller.start()
        try await waitUntil { captures == 1 }

        try await Task.sleep(for: .milliseconds(3250))
        XCTAssertFalse(controller.isAutoScrolling)
        XCTAssertTrue(scrolls.isEmpty)
        let retryHint = "No screen captured. Click Auto-Scroll to retry."
        XCTAssertEqual(controller.statusHint, retryHint)
        guard controller.statusHint == retryHint else { return }

        controller.toggleAutoScroll()
        try await waitUntil { controller.segmentCount > 0 }
        releaseCapture?.resume()
        releaseCapture = nil
        XCTAssertTrue(scrolls.allSatisfy { $0 > 0 })
    }

    @MainActor
    func testAutoScrollCanStartWhileAnOlderManualCaptureIsStalled() async throws {
        let page = ScrollingPage()
        var releaseCapture: CheckedContinuation<Void, Never>?
        var captureCount = 0
        var scrolls: [Int] = []
        let controller = try makeController(page, scroll: { points in
            scrolls.append(points)
            page.scroll(points)
        }) {
            captureCount += 1
            if captureCount == 1 {
                await withCheckedContinuation { releaseCapture = $0 }
            }
            return page.frame
        }
        defer {
            controller.stopAndCleanup()
            releaseCapture?.resume()
        }
        controller.start()
        try await waitUntil { releaseCapture != nil }

        controller.toggleAutoScroll()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(scrolls.contains { $0 > 0 })
    }

    @MainActor
    func testInvalidCaptureSizeDoesNotBecomeTheRestartPreview() async throws {
        let page = ScrollingPage()
        let firstFrame = page.frame
        let invalidFrame = try XCTUnwrap(firstFrame.cropped(
            to: PixelRect(x: 0, y: 0, width: firstFrame.width - 1, height: firstFrame.height)
        ))
        var validFrameAvailable = false
        let controller = try makeController(page, autoStart: true) {
            validFrameAvailable ? page.frame : invalidFrame
        }
        defer { controller.stopAndCleanup() }
        controller.start()
        try await waitUntil { !controller.isAutoScrolling }

        let retryHint = "No screen captured. Click Auto-Scroll to retry."
        XCTAssertEqual(controller.statusHint, retryHint)
        XCTAssertTrue(controller.thumbnailImage.flatMap(PixelBufferRGBA.init(cgImage:)) == firstFrame, "Invalid capture replaced the preview")
        guard controller.statusHint == retryHint else { return }

        validFrameAvailable = true
        controller.toggleAutoScroll()
        try await waitUntil { controller.segmentCount > 0 }
        XCTAssertEqual(controller.pixelWidth, firstFrame.width)
    }

    @MainActor
    func testMissingFrameIsRetriedBeforeThePageScrollsAgain() async throws {
        let page = ScrollingPage()
        var positions: [Int] = []
        let controller = try makeController(page, autoStart: true) {
            if page.top > 0 {
                positions.append(page.top)
                if positions.count == 1 { return nil }
            }
            return page.frame
        }
        defer { controller.stopAndCleanup() }
        controller.start()

        try await waitUntil { positions.count >= 2 }
        XCTAssertEqual(positions.first, positions.dropFirst().first)
    }

    @MainActor
    func testAutomaticRewindRecoversAJumpWithoutDuplicatingRows() async throws {
        let page = ScrollingPage(frameHeight: 24, height: 110)
        var crossedTheSeam = false
        var restored: [Int] = []
        let controller = try makeController(page, autoStart: true, scroll: { points in
            if points > 0, !crossedTheSeam {
                crossedTheSeam = true
                page.top = 30
            } else {
                page.scroll(points)
            }
        }, scrollPosition: { page.position }, restorePosition: { position in
            page.top = page.top(at: position)
            restored.append(page.top)
            return true
        }) { page.frame }
        defer { controller.stopAndCleanup() }
        controller.start()

        try await waitUntil { !controller.isAutoScrolling }
        XCTAssertEqual(restored, [0])
        XCTAssertEqual(controller.statusHint, "Reached the end. Copy or save the capture.")
        var output: PixelBufferRGBA?
        controller.onFinishCopy = { image, _ in output = PixelBufferRGBA(cgImage: image) }
        controller.finishAndCopy()
        try await waitUntil { output != nil }
        XCTAssertEqual(output, page.fullImage)
    }

    @MainActor
    func testEveryOutputKeepsTheFirstScreenOpenUntilThereIsALongScreenshot() async throws {
        let outputs: [(LongshotSessionController) -> Void] = [
            { $0.finishAndCopy() },
            { $0.finishAndSave() },
            { $0.finishAndSave(forceDialog: true) },
            { $0.finishAndAnnotate() },
            { $0.finishAndOCR() }
        ]
        for output in outputs {
            let page = ScrollingPage()
            let controller = try makeController(page) { page.frame }
            defer { controller.stopAndCleanup() }
            var outputHeight: Int?
            controller.onFinishCopy = { image, _ in outputHeight = image.height }
            controller.onFinishSave = { image, _, _ in outputHeight = image.height }
            controller.onFinishEdit = { image, _, _ in outputHeight = image.height }
            controller.onFinishOCR = { image in outputHeight = image.height }
            controller.start()

            output(controller)
            try await waitUntil { outputHeight != nil || controller.statusHint == "No long screenshot yet" }
            XCTAssertNil(outputHeight)
            guard outputHeight == nil else { return }

            page.top = 40
            try await waitUntil { controller.pixelHeight == 160 }
            output(controller)
            try await waitUntil { outputHeight != nil }
            XCTAssertEqual(outputHeight, 160)
        }
    }

    @MainActor
    func testSaveAsWaitsForTheLastScrollAndUsesTheCurrentViewport() async throws {
        let page = ScrollingPage()
        let resume = AsyncStream<Void>.makeStream()
        var scrollCaptureStarted = false
        let controller = try makeController(page, autoStart: true) {
            let frame = page.frame
            if page.top > 0, !scrollCaptureStarted {
                scrollCaptureStarted = true
                var waiting = resume.stream.makeAsyncIterator()
                _ = await waiting.next()
            }
            return frame
        }
        defer {
            controller.stopAndCleanup()
            resume.continuation.finish()
        }
        var output: (height: Int, saveAs: Bool)?
        controller.onFinishSave = { image, _, saveAs in output = (image.height, saveAs) }
        controller.start()
        try await waitUntil { scrollCaptureStarted }

        controller.finishAndSave(forceDialog: true)
        page.top += 12
        let expectedHeight = page.top + page.frameHeight
        resume.continuation.yield()
        try await waitUntil { output != nil }
        XCTAssertEqual(output?.height, expectedHeight)
        XCTAssertEqual(output?.saveAs, true)
        XCTAssertEqual(page.top + page.frameHeight, expectedHeight)
    }

    @MainActor
    func testUnmatchedLongScreenshotCanBeRejoinedManuallyBeforeOutput() async throws {
        let page = ScrollingPage()
        var shouldSkip = false
        var attemptedRecovery = false
        let controller = try makeController(page, autoStart: true, scroll: { points in
            if points < 0 {
                attemptedRecovery = true
            } else if shouldSkip {
                page.top = 360
            } else {
                page.scroll(points)
            }
        }) {
            if page.top > 0 { shouldSkip = true }
            return page.frame
        }
        defer { controller.stopAndCleanup() }
        var outputHeight: Int?
        controller.onFinishCopy = { image, _ in outputHeight = image.height }
        controller.start()

        try await waitUntil { !controller.isAutoScrolling }
        XCTAssertFalse(attemptedRecovery, "A wheel request alone cannot justify rewinding")
        XCTAssertEqual(controller.segmentCount, 1)
        XCTAssertEqual(controller.statusHint, "Stitch interrupted. Scroll manually to reconnect.")
        controller.finishAndCopy()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(outputHeight)

        page.top = 70
        try await waitUntil { controller.pixelHeight == 190 }
        controller.finishAndCopy()
        try await waitUntil { outputHeight != nil }
        XCTAssertEqual(outputHeight, 190)
    }

    @MainActor
    func testUndoingToTheFirstScreenStillPreservesTheOriginalStart() async throws {
        let page = ScrollingPage()
        var scrolls: [Int] = []
        let controller = try makeController(page, scroll: { points in
            scrolls.append(points)
        }) {
            page.frame
        }
        defer { controller.stopAndCleanup() }
        let originalStart = page.frame
        controller.start()
        page.top = 40
        try await waitUntil { controller.segmentCount == 1 }
        controller.undoLastSegment()
        XCTAssertEqual(controller.segmentCount, 0)

        page.top = 360
        controller.toggleAutoScroll()
        try await waitUntil { !controller.isAutoScrolling }

        XCTAssertTrue(scrolls.isEmpty)
        XCTAssertEqual(controller.statusHint, "Stitch interrupted. Scroll manually to reconnect.")
        page.top = 80
        try await waitUntil { controller.segmentCount == 1 }
        var output: PixelBufferRGBA?
        controller.onFinishCopy = { image, _ in output = PixelBufferRGBA(cgImage: image) }
        controller.finishAndCopy()
        try await waitUntil { output != nil }
        let exported = try XCTUnwrap(output)
        XCTAssertEqual(
            exported.cropped(to: PixelRect(x: 0, y: 0, width: originalStart.width, height: originalStart.height)),
            originalStart
        )
    }

    @MainActor
    func testPausingDuringRecoveryStopsFurtherWheelEvents() async throws {
        let page = ScrollingPage()
        var scrolls = 0
        var restoring = false
        let controller = try makeController(page, autoStart: true, scroll: { _ in
            scrolls += 1
            page.top = 200
        }, scrollPosition: { page.position }, restorePosition: { position in
            page.top = page.top(at: position)
            restoring = true
            return true
        }) { page.frame }
        defer { controller.stopAndCleanup() }
        controller.start()

        try await waitUntil { restoring }
        controller.pauseAutoScrolling()
        let pausedScrolls = scrolls
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(controller.isAutoScrolling)
        XCTAssertEqual(scrolls, pausedScrolls)
        XCTAssertEqual(page.top, 0)
    }

    @MainActor
    func testFirstFailedStepCanRestartFromThePreviewWithoutRewinding() async throws {
        let page = ScrollingPage()
        var canScrollNormally = false
        var moves: [Int] = []
        let controller = try makeController(page, autoStart: true, scroll: { points in
            moves.append(points)
            if canScrollNormally {
                page.scroll(points)
            } else {
                page.top = 200
            }
        }) { page.frame }
        defer { controller.stopAndCleanup() }
        controller.start()
        try await waitUntil { !controller.isAutoScrolling }

        XCTAssertFalse(moves.isEmpty)
        XCTAssertTrue(moves.allSatisfy { $0 > 0 })
        XCTAssertEqual(controller.segmentCount, 0)
        XCTAssertTrue(controller.canRestartFromPreview)
        XCTAssertEqual(controller.statusHint, "First segment did not match. You can start from the preview.")
        let newStart = page.frame
        XCTAssertEqual(controller.thumbnailImage.flatMap(PixelBufferRGBA.init(cgImage:)), newStart)
        canScrollNormally = true
        controller.toggleAutoScroll()
        try await waitUntil { controller.segmentCount > 0 }
        XCTAssertGreaterThan(controller.pixelHeight, newStart.height)
    }

    @MainActor
    func testManualScrollCanRecoverTheOriginalStartBeforeTheFirstSegment() async throws {
        let page = ScrollingPage()
        var shouldJump = true
        let controller = try makeController(page, autoStart: true, scroll: { points in
            if shouldJump { page.top = 200 } else { page.scroll(points) }
        }) { page.frame }
        defer { controller.stopAndCleanup() }
        let original = page.frame
        controller.start()
        try await waitUntil { controller.canRestartFromPreview }

        page.top = 0
        controller.handleManualScroll()
        try await waitUntil { !controller.canRestartFromPreview }
        XCTAssertFalse(controller.isAutoScrolling)
        XCTAssertEqual(controller.thumbnailImage.flatMap(PixelBufferRGBA.init(cgImage:)), original)

        shouldJump = false
        controller.toggleAutoScroll()
        try await waitUntil { controller.segmentCount > 0 }
        var output: PixelBufferRGBA?
        controller.onFinishCopy = { image, _ in output = PixelBufferRGBA(cgImage: image) }
        controller.finishAndCopy()
        try await waitUntil { output != nil }
        XCTAssertEqual(output?.cropped(to: PixelRect(x: 0, y: 0, width: original.width, height: original.height)), original)
    }

    @MainActor
    func testMissingCaptureAfterRestoreKeepsTheLastAvailableStartPreview() async throws {
        let page = ScrollingPage()
        var hasRewound = false
        var lastFrame = page.frame
        let controller = try makeController(page, autoStart: true, scroll: { _ in
            page.top = 200
        }, scrollPosition: { page.position }, restorePosition: { position in
            page.top = page.top(at: position)
            hasRewound = true
            return true
        }) {
            guard !hasRewound else { return nil }
            lastFrame = page.frame
            return lastFrame
        }
        defer { controller.stopAndCleanup() }
        controller.start()
        try await waitUntil { !controller.isAutoScrolling }

        XCTAssertTrue(hasRewound)
        XCTAssertTrue(controller.canRestartFromPreview)
        XCTAssertEqual(controller.thumbnailImage.flatMap(PixelBufferRGBA.init(cgImage:)), lastFrame)
    }

    @MainActor
    func testRestoreMustLandAtTheVerifiedPosition() async throws {
        let page = ScrollingPage()
        var restored: [Int] = []
        let controller = try makeController(page, autoStart: true, scroll: { _ in
            page.top = 200
        }, scrollPosition: { page.position }, restorePosition: { position in
            restored.append(page.top(at: position))
            page.top = 20
            return true
        }) { page.frame }
        defer { controller.stopAndCleanup() }
        controller.start()
        try await waitUntil { !controller.isAutoScrolling }

        XCTAssertEqual(restored, [0])
        XCTAssertEqual(controller.segmentCount, 0)
        XCTAssertTrue(controller.canRestartFromPreview)
        XCTAssertEqual(controller.thumbnailImage.flatMap(PixelBufferRGBA.init(cgImage:)), page.frame)
    }

    @MainActor
    func testRepeatedJumpsAndResumeKeepTheLastStitchedSegment() async throws {
        let page = ScrollingPage()
        var shouldJump = false
        var moves: [Int] = []
        var restored: [Int] = []
        let controller = try makeController(page, autoStart: true, scroll: { points in
            moves.append(points)
            if shouldJump {
                page.top = 240
            } else {
                page.scroll(points)
            }
        }, scrollPosition: { page.position }, restorePosition: { position in
            page.top = page.top(at: position)
            restored.append(page.top)
            return true
        }) {
            if page.top > 0 { shouldJump = true }
            return page.frame
        }
        defer { controller.stopAndCleanup() }
        controller.start()
        try await waitUntil { !controller.isAutoScrolling }

        XCTAssertEqual(controller.segmentCount, 1)
        XCTAssertEqual(restored, [controller.pixelHeight - page.frameHeight])
        XCTAssertFalse(controller.canRestartFromPreview)
        let scrollsBeforeResuming = moves
        let heightBeforeResuming = controller.pixelHeight
        for _ in 0..<2 {
            controller.toggleAutoScroll()
            try await waitUntil { !controller.isAutoScrolling }
        }
        XCTAssertEqual(moves, scrollsBeforeResuming)
        XCTAssertEqual(controller.pixelHeight, heightBeforeResuming)
    }

    @MainActor
    func testStationaryScreenDoesNotClaimThePageEnded() async throws {
        let page = ScrollingPage()
        let controller = try makeController(page, autoStart: true, scroll: { _ in }) { page.frame }
        defer { controller.stopAndCleanup() }
        controller.start()
        try await waitUntil { !controller.isAutoScrolling }

        XCTAssertEqual(controller.statusHint, "No new content")
        XCTAssertEqual(controller.segmentCount, 0)
    }

    @MainActor
    func testHeightLimitAllowsOutputOfTheAlreadyStitchedImage() async throws {
        let page = ScrollingPage()
        let controller = try makeController(page, autoStart: true, maxHeight: 205) { page.frame }
        defer { controller.stopAndCleanup() }
        var outputHeight: Int?
        controller.onFinishCopy = { image, _ in outputHeight = image.height }
        controller.start()

        try await waitUntil { controller.statusHint == "Height limit reached" }
        let acceptedHeight = controller.pixelHeight
        XCTAssertFalse(controller.isAutoScrolling)
        XCTAssertGreaterThan(acceptedHeight, page.frameHeight)
        XCTAssertLessThanOrEqual(acceptedHeight, 205)
        XCTAssertGreaterThan(page.top + page.frameHeight, 205)

        controller.finishAndCopy()
        try await waitUntil { outputHeight != nil }
        XCTAssertEqual(outputHeight, acceptedHeight)
    }

    @MainActor
    func testFirstSegmentOverTheLimitCanBeReplacedByAShorterScroll() async throws {
        let page = ScrollingPage()
        let controller = try makeController(page, autoStart: true, scroll: { _ in
            page.top = 42
        }, maxHeight: 150) { page.frame }
        defer { controller.stopAndCleanup() }
        var outputHeight: Int?
        controller.onFinishCopy = { image, _ in outputHeight = image.height }
        controller.start()

        try await waitUntil { controller.statusHint == "Height limit reached" }
        XCTAssertEqual(controller.segmentCount, 0)
        controller.finishAndCopy()
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertNil(outputHeight)
        XCTAssertEqual(controller.statusHint, "Height limit reached")

        page.top = 20
        try await waitUntil { controller.pixelHeight == 140 }
        controller.finishAndCopy()
        try await waitUntil { outputHeight != nil }
        XCTAssertEqual(outputHeight, 140)
    }

    @MainActor
    func testShortSelectionLeavesEnoughOverlapToContinue() async throws {
        let page = ScrollingPage(frameHeight: 48)
        let controller = try makeController(page, autoStart: true) { page.frame }
        defer { controller.stopAndCleanup() }
        controller.start()

        try await waitUntil { controller.segmentCount >= 2 }
        XCTAssertGreaterThan(controller.pixelHeight, 48)
    }

    @MainActor
    private func makeController(
        _ page: ScrollingPage,
        autoStart: Bool = false,
        scroll: ((Int) -> Void)? = nil,
        maxHeight: Int = 30_000,
        scrollPosition: @escaping () -> LongshotViewport.Position? = { nil },
        restorePosition: @escaping (LongshotViewport.Position) async -> Bool = { _ in false },
        capture: @escaping () async -> PixelBufferRGBA?
    ) throws -> LongshotSessionController {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let scale = screen.backingScaleFactor
        page.scale = Int(scale)
        let height = Double(page.frameHeight) / scale
        let mouseInUpperHalf = NSEvent.mouseLocation.y > screen.frame.midY
        let y = mouseInUpperHalf ? screen.frame.height - height - 130 : 100
        var config = AirSnipConfig()
        config.language = .en
        config.longshotMaxHeight = maxHeight
        let initialPosition = scrollPosition()
        return LongshotSessionController(
            screen: screen,
            viewportTopDown: ASRect(x: 50, y: y, width: Double(page.width) / scale, height: height),
            initialCrop: page.frame,
            config: config,
            autoStartScroll: autoStart,
            viewport: LongshotViewport(
                initialSource: nil,
                capture: { _ in
                    let before = scrollPosition()
                    guard let image = await capture() else { return nil }
                    let after = scrollPosition()
                    return LongshotViewport.Frame(
                        image: image, initialPosition: initialPosition, position: before == after ? after : nil
                    )
                },
                scroll: scroll ?? page.scroll,
                positionCursor: { _, _ in },
                hasAccessibilityPermission: { true },
                restorePosition: restorePosition
            )
        )
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    private final class ScrollingPage {
        let width = 64
        let frameHeight: Int
        private let height: Int
        let fullImage: PixelBufferRGBA
        var scale = 1
        var top = 0
        var repaintedRows = 0..<0

        init(frameHeight: Int = 120, height: Int = 480, repeatRows: Int? = nil) {
            self.frameHeight = frameHeight
            self.height = height
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            var random: UInt32 = 1
            for index in stride(from: 0, to: bytes.count, by: 4) {
                random = 1_664_525 &* random &+ 1_013_904_223
                bytes[index] = UInt8(truncatingIfNeeded: random >> 8)
                bytes[index + 1] = UInt8(truncatingIfNeeded: random >> 16)
                bytes[index + 2] = UInt8(truncatingIfNeeded: random >> 24)
            }
            if let repeatRows {
                let strip = Array(bytes.prefix(width * repeatRows * 4))
                bytes = bytes.indices.map { strip[$0 % strip.count] }
            }
            fullImage = PixelBufferRGBA(width: width, height: height, rgba: bytes)
        }

        var frame: PixelBufferRGBA {
            let crop = fullImage.cropped(to: PixelRect(x: 0, y: top, width: width, height: frameHeight))!
            let rows = repaintedRows.clamped(to: top..<(top + frameHeight))
            guard !rows.isEmpty else { return crop }
            var pixels = crop.rgba
            for index in stride(from: (rows.lowerBound - top) * width * 4, to: (rows.upperBound - top) * width * 4, by: 4) {
                pixels[index] &+= 80
            }
            return PixelBufferRGBA(width: width, height: frameHeight, rgba: pixels)
        }

        var position: LongshotViewport.Position {
            LongshotViewport.Position(targetID: 1, fraction: Double(top) / Double(height - frameHeight))
        }

        func top(at position: LongshotViewport.Position) -> Int {
            Int((position.fraction * Double(height - frameHeight)).rounded())
        }

        func scroll(_ points: Int) {
            top = min(height - frameHeight, max(0, top + points * scale))
        }
    }
}
