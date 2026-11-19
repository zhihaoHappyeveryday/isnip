import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PinDisplayState {
    let frame: CGRect
    let baseSize: CGSize
    let backingScale: Double
    let zoomScale: CGFloat
    let preferredOpacity: CGFloat
    let effectiveWindowOpacity: CGFloat
    let showBorder: Bool
    let isClickThrough: Bool
}

struct PinSnapshot {
    let image: CGImage
    let originalText: String?
    let displayState: PinDisplayState
}

@MainActor
final class ClosedPinHistory {
    nonisolated static let directoryName = "iSnip Pin History"

    private final class CloseBatch {
        var reportedWriteFailure = false
    }

    private struct Entry {
        enum Content {
            case pending(image: CGImage, originalText: String?)
            case stored(hasOriginalText: Bool)
        }

        let entryDirectory: URL
        let displayState: PinDisplayState
        let batch: CloseBatch
        var content: Content
    }

    private let sessionDirectories: PinHistorySessionDirectories
    private var entries: [Entry] = []
    private var inFlightEntryDirectory: URL?
    var onWriteFailure: (() -> Void)?

    init(registryURL: URL?) {
        sessionDirectories = PinHistorySessionDirectories(registryURL: registryURL)
    }

    var isEmpty: Bool { entries.isEmpty }

    func remember(_ snapshots: [PinSnapshot], limit: Int, historyRoot: URL) {
        guard limit > 0, !snapshots.isEmpty else { return }
        guard let sessionDirectory = try? sessionDirectories.sessionDirectory(in: historyRoot) else {
            onWriteFailure?()
            return
        }
        let batch = CloseBatch()
        entries.append(contentsOf: snapshots.suffix(limit).map { snapshot in
            Entry(
                entryDirectory: sessionDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
                displayState: snapshot.displayState,
                batch: batch,
                content: .pending(image: snapshot.image, originalText: snapshot.originalText)
            )
        })
        trim(to: limit)
        writeNext()
    }

    func trim(to limit: Int) {
        let excess = entries.count - limit
        guard excess > 0 else { return }
        for entry in entries.prefix(excess) { removeStoredFiles(for: entry) }
        entries.removeFirst(excess)
    }

    func restoreLast() -> (snapshot: PinSnapshot?, skippedUnreadable: Bool) {
        var skippedUnreadable = false
        while let entry = entries.popLast() {
            switch entry.content {
            case .pending(let image, let originalText):
                return (PinSnapshot(image: image, originalText: originalText, displayState: entry.displayState), skippedUnreadable)
            case .stored(let hasOriginalText):
                let snapshot = Self.readSnapshot(entry, hasOriginalText: hasOriginalText)
                removeStoredFiles(for: entry)
                if let snapshot { return (snapshot, skippedUnreadable) }
                skippedUnreadable = true
            }
        }
        return (nil, skippedUnreadable)
    }

    func finishSession() {
        entries.removeAll()
        sessionDirectories.finishSession()
    }

    nonisolated static func ensureHistoryRootExists(_ historyRoot: URL) throws {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: historyRoot.path, isDirectory: &isDirectory), isDirectory.boolValue { return }
        try files.createDirectory(at: historyRoot, withIntermediateDirectories: false)
    }

    private func writeNext() {
        guard inFlightEntryDirectory == nil,
              let entry = entries.first(where: {
                  if case .pending = $0.content { return true }
                  return false
              }), case .pending(let image, let originalText) = entry.content else { return }

        let entryDirectory = entry.entryDirectory
        inFlightEntryDirectory = entryDirectory
        let write = Task.detached(priority: .utility) {
            Self.writeSnapshot(image, originalText: originalText, to: entryDirectory)
        }
        let hasOriginalText = originalText != nil
        Task { [weak self] in
            let saved = await write.value
            guard let self else {
                Self.removeEntryDirectory(entryDirectory)
                return
            }
            self.completeWrite(at: entryDirectory, saved: saved, hasOriginalText: hasOriginalText)
        }
    }

    private func completeWrite(at entryDirectory: URL, saved: Bool, hasOriginalText: Bool) {
        inFlightEntryDirectory = nil
        defer { writeNext() }

        guard let index = entries.firstIndex(where: { $0.entryDirectory == entryDirectory }) else {
            // A restore or eviction can consume an entry before its write finishes.
            Self.removeEntryDirectory(entryDirectory)
            return
        }
        if saved {
            entries[index].content = .stored(hasOriginalText: hasOriginalText)
            return
        }
        let batch = entries.remove(at: index).batch
        if !batch.reportedWriteFailure {
            batch.reportedWriteFailure = true
            onWriteFailure?()
        }
    }

    private func removeStoredFiles(for entry: Entry) {
        if case .stored = entry.content { Self.removeEntryDirectory(entry.entryDirectory) }
    }

    private nonisolated static func writeSnapshot(_ image: CGImage, originalText: String?, to entryDirectory: URL) -> Bool {
        autoreleasepool {
            do {
                try FileManager.default.createDirectory(at: entryDirectory, withIntermediateDirectories: false)
                let imageURL = entryDirectory.appendingPathComponent("image.png")
                guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                if let originalText {
                    try originalText.write(to: entryDirectory.appendingPathComponent("original.txt"), atomically: false, encoding: .utf8)
                }
                return true
            } catch {
                removeEntryDirectory(entryDirectory)
                return false
            }
        }
    }

    private static func readSnapshot(_ entry: Entry, hasOriginalText: Bool) -> PinSnapshot? {
        let imageURL = entry.entryDirectory.appendingPathComponent("image.png")
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        let originalText = hasOriginalText
            ? try? String(contentsOf: entry.entryDirectory.appendingPathComponent("original.txt"), encoding: .utf8)
            : nil
        guard !hasOriginalText || originalText != nil else { return nil }
        return PinSnapshot(image: image, originalText: originalText, displayState: entry.displayState)
    }

    private nonisolated static func removeEntryDirectory(_ entryDirectory: URL) {
        try? FileManager.default.removeItem(at: entryDirectory)
    }
}

private final class PinHistorySessionDirectories {
    private let registryURL: URL?
    private let sessionID = UUID().uuidString
    private var registeredSessionDirectories: Set<URL> = []
    private var currentSessionDirectories: Set<URL> = []

    init(registryURL: URL?) {
        self.registryURL = registryURL
        if let registryURL, let data = try? Data(contentsOf: registryURL),
           let paths = try? JSONDecoder().decode(Set<URL>.self, from: data) {
            registeredSessionDirectories = paths.filter { url in
                url.isFileURL && UUID(uuidString: url.lastPathComponent) != nil
                    && url.deletingLastPathComponent().lastPathComponent == ClosedPinHistory.directoryName
            }
            removeSessionDirectories(registeredSessionDirectories)
        }
    }

    deinit { finishSession() }

    func sessionDirectory(in historyRoot: URL) throws -> URL {
        let sessionDirectory = historyRoot.appendingPathComponent(sessionID, isDirectory: true)
        if currentSessionDirectories.contains(sessionDirectory) { return sessionDirectory }

        removeSessionDirectories(registeredSessionDirectories.filter {
            !currentSessionDirectories.contains($0) && $0.deletingLastPathComponent() == historyRoot
        })
        let files = FileManager.default
        try ClosedPinHistory.ensureHistoryRootExists(historyRoot)
        // Register the session before writing its first file so an interrupted run can be cleaned up.
        let next = registeredSessionDirectories.union([sessionDirectory])
        try saveRegistry(next)
        registeredSessionDirectories = next
        do {
            try files.createDirectory(at: sessionDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            removeSessionDirectories([sessionDirectory])
            throw error
        }
        currentSessionDirectories.insert(sessionDirectory)
        return sessionDirectory
    }

    func finishSession() {
        removeSessionDirectories(currentSessionDirectories)
        currentSessionDirectories.removeAll()
    }

    private func removeSessionDirectories(_ directories: Set<URL>) {
        let files = FileManager.default
        let previous = registeredSessionDirectories
        for sessionDirectory in directories {
            do {
                try files.removeItem(at: sessionDirectory)
                registeredSessionDirectories.remove(sessionDirectory)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // An unavailable volume may still contain the session directory when reconnected.
                if files.fileExists(atPath: sessionDirectory.deletingLastPathComponent().deletingLastPathComponent().path) {
                    registeredSessionDirectories.remove(sessionDirectory)
                }
            } catch {}
        }
        if previous != registeredSessionDirectories { try? saveRegistry(registeredSessionDirectories) }
    }

    private func saveRegistry(_ directories: Set<URL>) throws {
        guard let registryURL else { return }
        let files = FileManager.default
        if directories.isEmpty {
            if files.fileExists(atPath: registryURL.path) { try files.removeItem(at: registryURL) }
        } else {
            try files.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(directories).write(to: registryURL, options: .atomic)
        }
    }
}
