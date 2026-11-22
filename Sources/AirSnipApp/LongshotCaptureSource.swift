import AppKit
import ApplicationServices
import ScreenCaptureKit
import AirSnipCore

/// Keeps the target and pixel coordinates fixed while a longshot is in progress.
@MainActor
final class LongshotCaptureSource {
    struct Frame {
        let image: PixelBufferRGBA
        let context: LongshotContext
        let position: Double?
        let measurement: LongshotScrollMeasurement?
    }

    enum Failure: Error {
        case targetChanged
        case frameUnavailable
    }

    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let target: SCWindow?
    private let excludedWindows: Set<Int>
    private let selection: PixelRect
    private let region: PixelRect
    private let captureTopOnScreen: CGFloat
    private let scrollArea: ScrollArea?
    private let scrollPoints: [CGPoint]
    private var scrollPointIndex = 0
    private var scrollAnchor: ScrollAnchor?
    private var confirmedViewport: Range<Int>?

    init(
        screen: NSScreen, viewport: ASRect, initialCrop: PixelBufferRGBA,
        targetWindow: WindowSnapCandidate?, excludingWindowNumbers: Set<Int>
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == number }) else {
            throw Failure.targetChanged
        }
        let origin = AccessibilityService.globalCGPoint(on: screen, localTopDownPoint: ASPoint(0, 0))
        let target = content.windows.first { $0.windowID == targetWindow?.windowID }
        if let targetWindow {
            let expectedFrame = targetWindow.unclippedRect.cgRect.offsetBy(dx: origin.x, dy: origin.y)
            guard target?.frame == expectedFrame else { throw Failure.targetChanged }
        }
        let selectionOnScreen = viewport.cgRect.offsetBy(dx: origin.x, dy: origin.y)
        let points = [(0.5, 0.46), (0.5, 0.78), (0.5, 0.23), (0.25, 0.46), (0.75, 0.46)].map { column, row in
            CGPoint(x: selectionOnScreen.minX + selectionOnScreen.width * column,
                    y: selectionOnScreen.minY + selectionOnScreen.height * row)
        }
        let processID = target?.owningApplication?.processID
        let area: ScrollArea?
        if let processID, AccessibilityService.hasPermission() {
            area = await Task.detached {
                ScrollArea.find(in: selectionOnScreen, points: points, processID: processID)
            }.value
        } else {
            area = nil
        }

        let scale = screen.backingScaleFactor
        let localScreen = CGRect(origin: .zero, size: screen.frame.size)
        let targetOnScreen = target?.frame.offsetBy(dx: -origin.x, dy: -origin.y)
        let scrollOnScreen = area?.bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let available = localScreen.intersection(targetOnScreen ?? localScreen)
        // Keep the visible bottom of the same window available when a short selection reaches the end.
        let horizontalMargin = viewport.width < 160 ? max(32, viewport.width / 2) : 0
        let contextBounds = available.intersection(scrollOnScreen ?? available)
        var sampleOnScreen = viewport.cgRect.insetBy(
            dx: -horizontalMargin, dy: -min(240, max(100, viewport.height))
        )
        if target != nil, !contextBounds.isEmpty, contextBounds.maxY > sampleOnScreen.maxY {
            sampleOnScreen.size.height = contextBounds.maxY - sampleOnScreen.minY
        }
        let contextOnScreen = sampleOnScreen.intersection(contextBounds)

        func pixels(_ rect: CGRect) -> PixelRect {
            let x = Int((rect.minX * scale).rounded())
            let y = Int((rect.minY * scale).rounded())
            return PixelRect(x: x, y: y,
                             width: Int((rect.maxX * scale).rounded()) - x,
                             height: Int((rect.maxY * scale).rounded()) - y)
        }
        let output = PixelRect(x: Int((viewport.minX * scale).rounded()),
                               y: Int((viewport.minY * scale).rounded()),
                               width: initialCrop.width, height: initialCrop.height)
        let context = contextOnScreen.isNull || contextOnScreen.isEmpty ? output : pixels(contextOnScreen)
        let x = min(context.x, output.x)
        let y = min(context.y, output.y)
        let width = max(context.maxX, output.maxX) - x
        let height = max(context.maxY, output.maxY) - y

        // ScreenCaptureKit can resample fractional-point rectangles, even at the requested native size.
        // Capture on whole points, then keep the original pixel boundaries for matching and export.
        let captureRect = CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale,
                                 width: CGFloat(width) / scale, height: CGFloat(height) / scale).integral
        let capture = pixels(captureRect)
        let sample = area == nil ? PixelRect(x: x, y: y, width: width, height: height) : context
        self.selection = PixelRect(x: output.x - capture.x, y: output.y - capture.y,
                                   width: output.width, height: output.height)
        self.region = PixelRect(x: sample.x - capture.x, y: sample.y - capture.y,
                                width: sample.width, height: sample.height)
        self.captureTopOnScreen = origin.y + captureRect.minY
        self.target = target
        self.excludedWindows = excludingWindowNumbers
        self.scrollArea = area
        self.scrollPoints = area.map { hit in
            [hit.point] + points.filter { $0 != hit.point && hit.bounds.contains($0) }
        } ?? points

        if let target {
            // Keep display-relative cropping while filtering out windows from other applications.
            filter = SCContentFilter(display: display, including: [target])
        } else {
            let excluded = content.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = captureRect
        configuration.width = capture.width
        configuration.height = capture.height
        configuration.captureResolution = .best
        configuration.ignoreShadowsDisplay = true
        configuration.scalesToFit = false
        configuration.showsCursor = false
        self.configuration = configuration
    }

    var scrollPoint: CGPoint { scrollPoints[scrollPointIndex] }

    var selectedBodyHeight: Int {
        return max(1, min(selection.maxY, region.maxY) - max(selection.y, region.y))
    }

    func positionCursor() {
        guard canScroll else { return }
        CGWarpMouseCursorPosition(scrollPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
        // A toolbar click can leave mouse tracking in the Dock or a different window.
        CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved,
                mouseCursorPosition: scrollPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    func tryAnotherScrollPoint() -> Bool {
        guard scrollPointIndex + 1 < scrollPoints.count else { return false }
        scrollPointIndex += 1
        confirmedViewport = nil
        return true
    }

    var hasInnerViewportAnchor: Bool {
        guard let scrollArea else { return false }
        return scrollAnchor?.ancestors.contains { $0.frame.height < scrollArea.bounds.height } == true
    }

    func confirmViewport(from frame: Frame) {
        if let rows = frame.measurement?.viewportRows {
            confirmedViewport = rows
        }
    }

    func rememberScrollAnchor(includeViewport: Bool) async {
        guard let scrollArea else { return }
        var point = scrollPoint
        if let confirmedViewport {
            // A reference lower in the live viewport stays visible across a normal downward step.
            let row = Double(confirmedViewport.lowerBound) + Double(confirmedViewport.count) * 0.75
            point.y = captureTopOnScreen + row / captureScale
        }
        let samplePoint = point
        scrollAnchor = await Task.detached { scrollArea.anchor(at: samplePoint, includeViewport: includeViewport) }.value
    }

    func capture(measuringOffset: Bool = false) async throws -> Frame {
        guard targetIsInPlace else { throw Failure.targetChanged }
        let anchor = measuringOffset ? scrollAnchor : nil
        let before = await scrollPosition(anchor: anchor)
        let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let after = await scrollPosition(anchor: anchor)
        guard targetIsInPlace else { throw Failure.targetChanged }
        guard before.position == after.position, screenshot.width == configuration.width, screenshot.height == configuration.height,
              let pixels = PixelBufferRGBA(cgImage: screenshot),
              let image = pixels.cropped(to: selection),
              image.width == selection.width, image.height == selection.height else {
            throw Failure.frameUnavailable
        }
        let measurement = before.movement == after.movement ? after.movement.flatMap(pixelMeasurement) : nil
        return Frame(image: image, context: LongshotContext(image: pixels, selection: selection, scrollRegion: region),
                     position: after.position, measurement: measurement)
    }

    private var captureScale: CGFloat {
        CGFloat(configuration.height) / configuration.sourceRect.height
    }

    private func pixelMeasurement(_ movement: AnchorMovement) -> LongshotScrollMeasurement? {
        let scale = captureScale
        let offset = movement.points * scale
        guard abs(offset) <= CGFloat(region.height) else { return nil }
        let viewport = movement.viewport.flatMap { frame -> Range<Int>? in
            let top = max(region.y, Int(((frame.minY - captureTopOnScreen) * scale).rounded()))
            let bottom = min(region.maxY, Int(((frame.maxY - captureTopOnScreen) * scale).rounded()))
            return bottom > top ? top..<bottom : nil
        }
        return LongshotScrollMeasurement(offset: Int(offset.rounded()), viewportRows: viewport)
    }

    func postScroll(_ points: Int) -> Bool {
        guard canScroll else { return false }
        AccessibilityService.postPixelScroll(at: scrollPoint, downwardPoints: points)
        return true
    }

    func restorePosition(_ position: Double) async -> Bool {
        guard canScroll, let scrollArea else { return false }
        let operation = Task.detached { scrollArea.restore(position) }
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private var canScroll: Bool {
        guard targetIsInPlace, let target else { return false }
        let point = ASPoint(scrollPoint.x, scrollPoint.y)
        let visible = ScreenCaptureService.queryOnScreenWindowsGlobalTopDown(excludingWindowNumbers: excludedWindows)
        return visible.first(where: { $0.globalRectTopDown.contains(point) })?.windowID == target.windowID
    }

    private var targetIsInPlace: Bool {
        guard let target else { return true }
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, target.windowID) as? [[String: Any]]
        guard let item = windows?.first,
              item[kCGWindowIsOnscreen as String] as? Bool != false,
              let bounds = item[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
        return frame == target.frame
    }

    private func scrollPosition(anchor: ScrollAnchor?) async -> (position: Double?, movement: AnchorMovement?) {
        guard let scrollArea else { return (nil, nil) }
        return await Task.detached {
            (scrollArea.position, anchor.flatMap { scrollArea.verticalMovement(from: $0) })
        }.value
    }

    private struct ScrollAnchor: @unchecked Sendable {
        let element: AXUIElement
        let frame: CGRect
        let point: CGPoint
        let ancestors: [(element: AXUIElement, frame: CGRect)]
    }

    private struct AnchorMovement: Equatable, Sendable {
        let points: CGFloat
        let viewport: CGRect?
    }

    private struct ScrollArea: @unchecked Sendable {
        let element: AXUIElement
        let bounds: CGRect
        let bar: AXUIElement?
        let point: CGPoint
        let processID: pid_t

        var position: Double? {
            guard let bar, let value = Self.attribute(kAXValueAttribute, of: bar) as? NSNumber,
                  (0...1).contains(value.doubleValue) else { return nil }
            return value.doubleValue
        }

        func anchor(at point: CGPoint, includeViewport: Bool) -> ScrollAnchor? {
            guard let hit = element(at: point),
                  let frame = Self.bounds(of: hit), frame.contains(point),
                  frame.height < bounds.height / 2 else { return nil }
            var ancestors: [(AXUIElement, CGRect)] = []
            if includeViewport {
                var child = hit
                for _ in 0..<4 {
                    guard let parent = Self.elementAttribute(kAXParentAttribute, of: child) else { break }
                    if CFEqual(parent, element) { break }
                    if let enclosing = Self.bounds(of: parent),
                       enclosing.contains(point), enclosing.height > frame.height, bounds.contains(enclosing) {
                        ancestors.append((parent, enclosing))
                    }
                    child = parent
                }
            }
            return ScrollAnchor(element: hit, frame: frame, point: point, ancestors: ancestors)
        }

        func verticalMovement(from anchor: ScrollAnchor) -> AnchorMovement? {
            // Refresh the hit test so the target app reports current element geometry.
            guard let hit = element(at: anchor.point),
                  let current = Self.bounds(of: anchor.element),
                  current.size == anchor.frame.size, current.minX == anchor.frame.minX else { return nil }
            let movement = anchor.frame.minY - current.minY
            guard movement != 0 || CFEqual(hit, anchor.element) else { return nil }
            // The nearest ancestor that stayed in place bounds this moving content, including nested web panes.
            let viewport = movement == 0 ? nil : anchor.ancestors.first { Self.bounds(of: $0.element) == $0.frame }?.frame
            return AnchorMovement(points: movement, viewport: viewport)
        }

        private func element(at point: CGPoint) -> AXUIElement? {
            let app = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(app, 0.15)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return nil }
            return hit
        }

        func restore(_ position: Double) -> Bool {
            let app = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(app, 0.15)
            guard let current = Self.at(point, in: app, processID: processID),
                  CFEqual(current.element, element), let bar, let currentBar = current.bar,
                  CFEqual(bar, currentBar), !Task.isCancelled else { return false }
            return AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: position)) == .success
        }

        static func find(in selection: CGRect, points: [CGPoint], processID: pid_t) -> ScrollArea? {
            let app = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(app, 0.15)
            var candidates: [(area: ScrollArea, hits: Int, overlap: CGFloat)] = []
            for point in points {
                guard let area = at(point, in: app, processID: processID) else { continue }
                let overlap = selection.intersection(area.bounds)
                guard !overlap.isEmpty else { continue }
                if let index = candidates.firstIndex(where: { CFEqual($0.area.element, area.element) }) {
                    candidates[index].hits += 1
                } else {
                    candidates.append((area, 1, overlap.width * overlap.height))
                }
            }
            return candidates.max {
                $0.hits == $1.hits ? $0.overlap < $1.overlap : $0.hits < $1.hits
            }?.area
        }

        private static func at(_ point: CGPoint, in app: AXUIElement, processID: pid_t) -> ScrollArea? {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return nil }
            for _ in 0..<12 {
                guard let item = hit else { return nil }
                if attribute(kAXRoleAttribute, of: item) as? String == kAXScrollAreaRole,
                   let bounds = bounds(of: item), bounds.contains(point) {
                    return ScrollArea(element: item, bounds: bounds,
                                      bar: elementAttribute(kAXVerticalScrollBarAttribute, of: item),
                                      point: point, processID: processID)
                }
                hit = elementAttribute(kAXParentAttribute, of: item)
            }
            return nil
        }

        private static func bounds(of element: AXUIElement) -> CGRect? {
            guard let location = attribute(kAXPositionAttribute, of: element),
                  let dimensions = attribute(kAXSizeAttribute, of: element),
                  CFGetTypeID(location) == AXValueGetTypeID(),
                  CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
            var point = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(location, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(dimensions, to: AXValue.self), .cgSize, &size) else { return nil }
            return CGRect(origin: point, size: size)
        }

        private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
            guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(value, to: AXUIElement.self)
        }

        private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
    }
}
