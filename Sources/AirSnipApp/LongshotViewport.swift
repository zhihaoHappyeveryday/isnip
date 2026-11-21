import AppKit
import ApplicationServices
import AirSnipCore

/// The capture and scrolling operations a longshot session needs from the desktop.
@MainActor
struct LongshotViewport {
    struct Source: Equatable {
        let windowID: UInt32
        let title: String
        var scrollTargetID: Int?

        func matches(_ capture: Source) -> Bool {
            windowID == capture.windowID && title == capture.title &&
                (scrollTargetID == nil || scrollTargetID == capture.scrollTargetID)
        }
    }

    struct Position: Equatable {
        let targetID: Int
        let fraction: Double

        var isAtEnd: Bool { fraction == 1 }
    }

    struct Frame {
        let image: PixelBufferRGBA
        var source: Source?
        var reference: LongshotReference?
        var initialReference: LongshotReference?
        var initialPosition: Position?
        var position: Position?
        var needsTarget = false
    }

    struct StartPosition {
        fileprivate let windowID: UInt32
        fileprivate let area: LongshotScrollArea
        fileprivate let fraction: Double

        func stillAtStart() async -> Bool {
            let area = area
            let fraction = fraction
            return await Task.detached { area.isCurrent() && area.fraction == fraction }.value
        }
    }

    let initialSource: Source?
    let capture: (Set<Int>) async -> Frame?
    let scroll: (Int) -> Void
    let positionCursor: (NSRect?, () -> Bool) async -> Void
    let hasAccessibilityPermission: () -> Bool
    let restorePosition: (Position) async -> Bool
}

extension LongshotViewport {
    static func desktop(
        screen: NSScreen, selection: ASRect, snapshot: CapturedScreenSnapshot?, startPosition: StartPosition? = nil
    ) -> Self {
        let desktop = DesktopLongshotViewport(screen: screen, selection: selection, snapshot: snapshot,
                                             startPosition: startPosition)
        return Self(
            initialSource: desktop.initialSource,
            capture: desktop.capture,
            scroll: desktop.scroll,
            positionCursor: desktop.positionCursor,
            hasAccessibilityPermission: AccessibilityService.hasPermission,
            restorePosition: desktop.restorePosition
        )
    }

    static func captureStartPosition() async -> StartPosition? {
        guard AccessibilityService.hasPermission() else { return nil }
        let mouse = CGEvent(source: nil)?.location
        let windows = ScreenCaptureService.queryOnScreenWindowsGlobalTopDown()
        guard let window = windows.first(where: { window in
            mouse.map { window.globalRectTopDown.cgRect.contains($0) } ?? false
        }) ?? windows.first else { return nil }
        let bounds = window.globalRectTopDown.cgRect
        let point = mouse.flatMap { bounds.contains($0) ? $0 : nil } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        return await Task.detached {
            guard let area = LongshotScrollArea.at(point, processID: window.processID), let fraction = area.fraction else { return nil }
            return StartPosition(windowID: window.windowID, area: area, fraction: fraction)
        }.value
    }
}

@MainActor
private final class DesktopLongshotViewport {
    private let screen: NSScreen
    private let selection: ASRect
    private let screenOrigin: CGPoint
    private var snapshot: CapturedScreenSnapshot?
    private let startPosition: LongshotViewport.StartPosition?
    let initialSource: LongshotViewport.Source?

    private var region = LongshotScrollArea.Resolution.selection
    private var target: ScreenCaptureService.GlobalWindowDescriptor?
    private var targetID = 0
    private var pointerInTarget: CGPoint?
    private var excludedWindows: Set<Int> = []

    init(screen: NSScreen, selection: ASRect, snapshot: CapturedScreenSnapshot?, startPosition: LongshotViewport.StartPosition?) {
        self.screen = screen
        self.selection = selection
        self.snapshot = snapshot
        self.startPosition = startPosition
        self.screenOrigin = AccessibilityService.globalCGPoint(on: screen, localTopDownPoint: ASPoint(0, 0))
        self.initialSource = snapshot?.windowsLocalTopDown
            .first { $0.rect.contains(ASPoint(selection.midX, selection.midY)) }
            .map { LongshotViewport.Source(windowID: $0.windowID, title: $0.title) }
    }

    private var selectionGlobal: CGRect {
        selection.cgRect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y)
    }

    private var scrollRect: CGRect {
        guard case .area(let area) = region, let target else { return selection.cgRect }
        return area.frame.intersection(target.globalRectTopDown.cgRect)
            .offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
            .intersection(CGRect(origin: .zero, size: screen.frame.size))
    }

    private var mouseGlobal: CGPoint {
        CGPoint(x: NSEvent.mouseLocation.x, y: screenOrigin.y + screen.frame.maxY - NSEvent.mouseLocation.y)
    }

    func capture(excluding windows: Set<Int>) async -> LongshotViewport.Frame? {
        excludedWindows = windows
        let visible = ScreenCaptureService.queryOnScreenWindowsGlobalTopDown(excludingWindowNumbers: windows)
        let rect = selectionGlobal
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let mouse = mouseGlobal
        let window = visible.first { $0.globalRectTopDown.cgRect.contains(center) }
        var source = window.map { LongshotViewport.Source(windowID: $0.windowID, title: $0.title) }
        let mayInspect = AccessibilityService.hasPermission()
        let otherWindow = visible.prefix { $0.windowID != window?.windowID }
            .contains { $0.globalRectTopDown.cgRect.intersects(rect) }

        if let window, mayInspect, !otherWindow {
            if case .needsTarget = region {
                guard rect.contains(mouse) else {
                    return await captureSelection(excluding: windows, source: source, needsTarget: true)
                }
                await resolveRegion(of: window, mouse: mouse)
            } else if target?.windowID != window.windowID || target?.title != window.title ||
                        target?.globalRectTopDown != window.globalRectTopDown {
                await resolveRegion(of: window, mouse: mouse)
            } else if case .area(let area) = region, !(await Task.detached { area.isCurrent() }.value) {
                await resolveRegion(of: window, mouse: mouse)
            }
        } else {
            target = nil
            region = .needsTarget
        }
        guard !Task.isCancelled else { return nil }
        if case .needsTarget = region {
            return await captureSelection(excluding: windows, source: source, needsTarget: mayInspect)
        }
        guard case .area(let area) = region, let window else {
            snapshot = nil
            return await captureSelection(excluding: windows, source: source, needsTarget: false)
        }
        source?.scrollTargetID = area.identity
        if scrollRect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y).contains(mouse) {
            let matches = await Task.detached { area.containsTarget(at: mouse) }.value
            guard !Task.isCancelled else { return nil }
            pointerInTarget = matches ? mouse : nil
        } else {
            pointerInTarget = nil
        }

        let inScreen = scrollRect
        let body = inScreen.intersection(selection.cgRect)
        guard body.height > 0, body.width >= selection.width - 1 else {
            return await captureSelection(excluding: windows, source: source, needsTarget: false)
        }

        // One capture keeps the selection and the larger sample on the same frame.
        let horizontal = min(160, max(48, selection.width / 2))
        let vertical = min(240, max(80, selection.height))
        let sampleRect = inScreen.intersection(selection.cgRect.insetBy(dx: -horizontal, dy: -vertical))
        let sampleOnScreen = sampleRect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y)
        guard visible.prefix(while: { $0.windowID != window.windowID }).allSatisfy({
            !$0.globalRectTopDown.cgRect.intersects(sampleOnScreen)
        }) else {
            return await captureSelection(excluding: windows, source: source, needsTarget: false)
        }
        let sample = pixels(in: sampleRect)
        let output = pixels(in: selection.cgRect)
        let union = CGRect(x: sample.x, y: sample.y, width: sample.width, height: sample.height)
            .union(CGRect(x: output.x, y: output.y, width: output.width, height: output.height))
        let scale = Double(screen.backingScaleFactor)
        let captureRect = ASRect(x: union.minX / scale, y: union.minY / scale,
                                 width: union.width / scale, height: union.height / scale)
        let capturedTargetID = targetID
        let before = await Task.detached { area.fraction }.value
        guard !Task.isCancelled,
              let frame = await ScreenCaptureService.captureDisplayRegion(
                screen: screen, localTopDownRect: captureRect, excludingWindowNumbers: windows
              ), !Task.isCancelled, capturedTargetID == targetID else { return nil }
        let after = await Task.detached { area.fraction }.value
        guard !Task.isCancelled, capturedTargetID == targetID,
              let image = frame.cropped(to: output.offsetBy(dx: -Int(union.minX), dy: -Int(union.minY))),
              let referenceImage = frame.cropped(to: sample.offsetBy(dx: -Int(union.minX), dy: -Int(union.minY))) else { return nil }
        let bodyPixels = pixels(in: body)
        let rows = (bodyPixels.y - output.y)..<(bodyPixels.y + bodyPixels.height - output.y)
        let selectionTop = output.y - sample.y
        let reference = LongshotReference(image: referenceImage, bodyRows: rows, selectionTopInReference: selectionTop)
        let initialReference: LongshotReference?
        if let source, initialSource?.matches(source) == true, let snapshot,
           let frozenWindow = snapshot.windowsLocalTopDown.first(where: { $0.windowID == window.windowID }),
           frozenWindow.rect.cgRect.contains(sampleRect),
           snapshot.windowsLocalTopDown.prefix(while: { $0.windowID != window.windowID }).allSatisfy({
               !$0.rect.cgRect.intersects(sampleRect)
           }), let initial = snapshot.rawBuffer.cropped(to: sample) {
            initialReference = LongshotReference(image: initial, bodyRows: rows, selectionTopInReference: selectionTop)
        } else {
            initialReference = nil
        }
        snapshot = nil
        let position = before == after ? after.map {
            LongshotViewport.Position(targetID: area.identity, fraction: $0)
        } : nil
        let initialPosition = startPosition.flatMap { start -> LongshotViewport.Position? in
            guard start.windowID == window.windowID, CFEqual(start.area.element, area.element),
                  start.area.frame == area.frame else { return nil }
            return LongshotViewport.Position(targetID: area.identity, fraction: start.fraction)
        }
        return LongshotViewport.Frame(
            image: image, source: source, reference: reference, initialReference: initialReference,
            initialPosition: initialPosition, position: position
        )
    }

    private func captureSelection(
        excluding windows: Set<Int>, source: LongshotViewport.Source?, needsTarget: Bool
    ) async -> LongshotViewport.Frame? {
        let image = await ScreenCaptureService.captureDisplayRegion(
            screen: screen, localTopDownRect: selection, excludingWindowNumbers: windows
        )
        return image.map { LongshotViewport.Frame(image: $0, source: source, needsTarget: needsTarget) }
    }

    private func resolveRegion(of window: ScreenCaptureService.GlobalWindowDescriptor, mouse: CGPoint) async {
        let rect = selectionGlobal
        let selected = await Task.detached {
            LongshotScrollArea.resolve(processID: window.processID, selected: rect, mouse: mouse)
        }.value
        guard !Task.isCancelled else { return }
        targetID += 1
        target = window
        region = selected
        pointerInTarget = nil
    }

    func positionCursor(avoiding rect: NSRect?, isCurrent: () -> Bool) async {
        switch region {
        case .needsTarget:
            return
        case .selection:
            guard isCurrent(), scrollPoint == nil || rect?.contains(NSEvent.mouseLocation) == true else { return }
            AccessibilityService.moveCursorIntoViewportIfNeeded(
                screen: screen, viewportTopDown: selection, avoidAppKitRect: rect
            )
        case .area(let area):
            let mouse = mouseGlobal
            let pointsToTarget = rect?.contains(NSEvent.mouseLocation) != true &&
                scrollRect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y).contains(mouse)
            let matches = pointsToTarget ? await Task.detached { area.containsTarget(at: mouse) }.value : false
            guard isCurrent(), mouse == mouseGlobal else { return }
            if matches {
                pointerInTarget = mouse
                return
            }
            guard targetIsVisible(at: area.point) else { return }
            CGWarpMouseCursorPosition(area.point)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    private var scrollPoint: CGPoint? {
        let bounds = scrollRect.offsetBy(dx: screenOrigin.x, dy: screenOrigin.y)
        let mouse = mouseGlobal
        guard bounds.contains(mouse) else { return nil }
        if case .area(let area) = region {
            let verified = pointerInTarget ?? area.point
            guard hypot(mouse.x - verified.x, mouse.y - verified.y) <= 1 ||
                  hypot(mouse.x - area.point.x, mouse.y - area.point.y) <= 1 else { return nil }
        }
        return mouse
    }

    func scroll(_ amount: Int) {
        guard let point = scrollPoint, targetIsVisible(at: point) else { return }
        AccessibilityService.postPixelScroll(at: point, downwardPoints: amount)
    }

    func restorePosition(_ position: LongshotViewport.Position) async -> Bool {
        guard case .area(let area) = region, position.targetID == area.identity,
              let target, let point = scrollPoint, targetIsVisible(at: point) else { return false }
        let request = Task.detached { area.restore(position.fraction, at: point, processID: target.processID) }
        return await withTaskCancellationHandler {
            await request.value
        } onCancel: {
            request.cancel()
        }
    }

    private func targetIsVisible(at point: CGPoint) -> Bool {
        guard let target else { return false }
        let window = ScreenCaptureService.queryOnScreenWindowsGlobalTopDown(excludingWindowNumbers: excludedWindows)
            .first { $0.globalRectTopDown.cgRect.contains(point) }
        return window?.windowID == target.windowID && window?.title == target.title &&
               window?.globalRectTopDown == target.globalRectTopDown
    }

    private func pixels(in rect: CGRect) -> PixelRect {
        let scale = Double(screen.backingScaleFactor)
        let x = Int(ceil(rect.minX * scale - 0.001))
        let y = Int(ceil(rect.minY * scale - 0.001))
        return PixelRect(x: x, y: y, width: max(0, Int(floor(rect.maxX * scale + 0.001)) - x),
                         height: max(0, Int(floor(rect.maxY * scale + 0.001)) - y))
    }
}

fileprivate struct LongshotScrollArea: @unchecked Sendable {
    enum Resolution: Sendable {
        case selection
        case area(LongshotScrollArea)
        case needsTarget
    }

    let element: AXUIElement
    let frame: CGRect
    let verticalBar: AXUIElement?
    let point: CGPoint
    let processID: pid_t

    var identity: Int { Int(truncatingIfNeeded: CFHash(element)) }

    var fraction: Double? {
        guard let verticalBar, let number = attribute(kAXValueAttribute, of: verticalBar) as? NSNumber,
              (0...1).contains(number.doubleValue) else { return nil }
        return number.doubleValue
    }

    func isCurrent() -> Bool {
        guard let current = Self.at(point, processID: processID) else { return false }
        return CFEqual(element, current.element) && frame == current.frame
    }

    func containsTarget(at point: CGPoint) -> Bool {
        guard let current = Self.at(point, processID: processID) else { return false }
        return CFEqual(element, current.element)
    }

    func restore(_ fraction: Double, at point: CGPoint, processID: pid_t) -> Bool {
        // Restore on the same live scrollbar. Equivalent bars in another tab are not interchangeable.
        guard let current = Self.at(point, processID: processID), CFEqual(current.element, element),
              let verticalBar, let currentBar = current.verticalBar, CFEqual(currentBar, verticalBar) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(currentBar, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue, !Task.isCancelled else { return false }
        return AXUIElementSetAttributeValue(currentBar, kAXValueAttribute as CFString, NSNumber(value: fraction)) == .success
    }

    static func resolve(processID: pid_t, selected: CGRect, mouse: CGPoint) -> Resolution {
        guard processID > 0, processID != getpid() else { return .selection }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let probes = [
            CGPoint(x: selected.minX + selected.width * 0.24, y: selected.minY + selected.height * 0.20),
            CGPoint(x: selected.minX + selected.width * 0.76, y: selected.minY + selected.height * 0.20),
            CGPoint(x: selected.minX + selected.width * 0.24, y: selected.minY + selected.height * 0.82),
            CGPoint(x: selected.minX + selected.width * 0.76, y: selected.minY + selected.height * 0.82),
            CGPoint(x: selected.midX, y: selected.midY)
        ]
        var areas: [LongshotScrollArea] = []
        for point in probes {
            if let area = at(point, in: app, processID: processID), !areas.contains(where: { CFEqual($0.element, area.element) }) {
                areas.append(area)
            }
        }
        if areas.count == 1 { return .area(areas[0]) }
        if areas.isEmpty { return .selection }
        if selected.contains(mouse), let pointed = at(mouse, in: app, processID: processID) { return .area(pointed) }
        return .needsTarget
    }

    static func at(_ point: CGPoint, processID: pid_t) -> LongshotScrollArea? {
        guard processID > 0, processID != getpid() else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        return at(point, in: app, processID: processID)
    }

    private static func at(_ point: CGPoint, in app: AXUIElement, processID: pid_t) -> LongshotScrollArea? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success else { return nil }
        var candidate = hit
        for _ in 0..<12 {
            guard let element = candidate else { return nil }
            if attribute(kAXRoleAttribute, of: element) as? String == kAXScrollAreaRole,
               let frame = bounds(of: element), frame.contains(point) {
                let bar = elementAttribute(kAXVerticalScrollBarAttribute, of: element)
                return LongshotScrollArea(element: element, frame: frame, verticalBar: bar, point: point, processID: processID)
            }
            candidate = elementAttribute(kAXParentAttribute, of: element)
        }
        return nil
    }

    private static func bounds(of element: AXUIElement) -> CGRect? {
        guard let pointValue = attribute(kAXPositionAttribute, of: element),
              let sizeValue = attribute(kAXSizeAttribute, of: element),
              CFGetTypeID(pointValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(pointValue, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}

private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

private extension ASRect {
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}

private extension PixelRect {
    func offsetBy(dx: Int, dy: Int) -> PixelRect {
        PixelRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}
