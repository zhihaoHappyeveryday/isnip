import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PinPresentation {
    let frame: CGRect
    let baseSize: CGSize
    let backingScale: Double
    let zoomScale: CGFloat
    let opacity: CGFloat
    let windowAlpha: CGFloat
    let showBorder: Bool
    let isClickThrough: Bool
}

struct PinSnapshot {
    let image: CGImage
    let originalText: String?
    let presentation: PinPresentation
}

@MainActor
final class ClosedPinHistory {
    nonisolated static let directoryName = "iSnip Pin History"

    private final class Batch {
        var reportedWriteFailure = false
    }

    private struct Record {
        enum Content {
            case pending(image: CGImage, originalText: String?)
            case stored(hasOriginalText: Bool)
        }

        let directory: URL
        let presentation: PinPresentation
        let batch: Batch
        var content: Content
    }

    private let folders: PinHistoryFolders
    private var records: [Record] = []
    private var writing: URL?
    var onWriteFailure: (() -> Void)?

    init(registryURL: URL?) {
        folders = PinHistoryFolders(registryURL: registryURL)
    }

    var isEmpty: Bool { records.isEmpty }

    func remember(_ snapshots: [PinSnapshot], limit: Int, root: URL) {
        guard limit > 0, !snapshots.isEmpty else { return }
        guard let sessionDirectory = try? folders.prepare(in: root) else {
            onWriteFailure?()
            return
        }
        let batch = Batch()
        records.append(contentsOf: snapshots.suffix(limit).map { snapshot in
            Record(
                directory: sessionDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true),
                presentation: snapshot.presentation,
                batch: batch,
                content: .pending(image: snapshot.image, originalText: snapshot.originalText)
            )
        })
        trim(to: limit)
        writeNext()
    }

    func trim(to limit: Int) {
        let excess = records.count - limit
        guard excess > 0 else { return }
        for record in records.prefix(excess) { discard(record) }
        records.removeFirst(excess)
    }

    func restoreLast() -> (snapshot: PinSnapshot?, skippedUnreadable: Bool) {
        var skippedUnreadable = false
        while let record = records.popLast() {
            switch record.content {
            case .pending(let image, let originalText):
                return (PinSnapshot(image: image, originalText: originalText, presentation: record.presentation), skippedUnreadable)
            case .stored(let hasOriginalText):
                let snapshot = Self.read(record, hasOriginalText: hasOriginalText)
                discard(record)
                if let snapshot { return (snapshot, skippedUnreadable) }
                skippedUnreadable = true
            }
        }
        return (nil, skippedUnreadable)
    }

    func finishSession() {
        records.removeAll()
        folders.finishSession()
    }

    nonisolated static func prepareRoot(_ root: URL) throws {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue { return }
        try files.createDirectory(at: root, withIntermediateDirectories: false)
    }

    private func writeNext() {
        guard writing == nil,
              let record = records.first(where: {
                  if case .pending = $0.content { return true }
                  return false
              }), case .pending(let image, let originalText) = record.content else { return }

        let directory = record.directory
        writing = directory
        let write = Task.detached(priority: .utility) {
            Self.write(image, originalText: originalText, to: directory)
        }
        let hasOriginalText = originalText != nil
        Task { [weak self] in
            let saved = await write.value
            guard let self else {
                Self.remove(directory)
                return
            }
            self.writing = nil
            if let index = self.records.firstIndex(where: { $0.directory == directory }) {
                if saved {
                    self.records[index].content = .stored(hasOriginalText: hasOriginalText)
                } else {
                    let batch = self.records.remove(at: index).batch
                    if !batch.reportedWriteFailure {
                        batch.reportedWriteFailure = true
                        self.onWriteFailure?()
                    }
                }
            } else {
                Self.remove(directory)
            }
            self.writeNext()
        }
    }

    private func discard(_ record: Record) {
        if case .stored = record.content { Self.remove(record.directory) }
    }

    private nonisolated static func write(_ image: CGImage, originalText: String?, to directory: URL) -> Bool {
        autoreleasepool {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let imageURL = directory.appendingPathComponent("image.png")
                guard let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                if let originalText {
                    try originalText.write(to: directory.appendingPathComponent("original.txt"), atomically: false, encoding: .utf8)
                }
                return true
            } catch {
                remove(directory)
                return false
            }
        }
    }

    private static func read(_ record: Record, hasOriginalText: Bool) -> PinSnapshot? {
        let directory = record.directory
        let imageURL = directory.appendingPathComponent("image.png")
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        let originalText = hasOriginalText
            ? try? String(contentsOf: directory.appendingPathComponent("original.txt"), encoding: .utf8)
            : nil
        guard !hasOriginalText || originalText != nil else { return nil }
        return PinSnapshot(image: image, originalText: originalText, presentation: record.presentation)
    }

    private nonisolated static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class PinHistoryFolders {
    private let registryURL: URL?
    private let sessionID = UUID().uuidString
    private var registered: Set<URL> = []
    private var active: Set<URL> = []

    init(registryURL: URL?) {
        self.registryURL = registryURL
        if let registryURL, let data = try? Data(contentsOf: registryURL),
           let paths = try? JSONDecoder().decode(Set<URL>.self, from: data) {
            registered = paths.filter { url in
                url.isFileURL && UUID(uuidString: url.lastPathComponent) != nil
                    && url.deletingLastPathComponent().lastPathComponent == ClosedPinHistory.directoryName
            }
            clean(registered)
        }
    }

    deinit { finishSession() }

    func prepare(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(sessionID, isDirectory: true)
        if active.contains(directory) { return directory }

        clean(registered.filter { !active.contains($0) && $0.deletingLastPathComponent() == root })
        let files = FileManager.default
        try ClosedPinHistory.prepareRoot(root)
        // Register the session before writing its first file so an interrupted run can be cleaned up.
        let next = registered.union([directory])
        try save(next)
        registered = next
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            clean([directory])
            throw error
        }
        active.insert(directory)
        return directory
    }

    func finishSession() {
        clean(active)
        active.removeAll()
    }

    private func clean(_ directories: Set<URL>) {
        let files = FileManager.default
        let previous = registered
        for directory in directories {
            do {
                try files.removeItem(at: directory)
                registered.remove(directory)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // An unavailable volume may still contain the session directory when reconnected.
                if files.fileExists(atPath: directory.deletingLastPathComponent().deletingLastPathComponent().path) {
                    registered.remove(directory)
                }
            } catch {}
        }
        if previous != registered { try? save(registered) }
    }

    private func save(_ directories: Set<URL>) throws {
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
