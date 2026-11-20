import AirSnipCore
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PinDisplayState: Codable {
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
    private final class CloseBatch {
        var reportedWriteFailure = false
    }

    private struct HistoryRootIdentity: Codable, Hashable {
        let fileNumber: UInt64
        let volumeUUID: String?

        init?(at url: URL) {
            let directory = url.resolvingSymlinksInPath()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let number = attributes[.systemFileNumber] as? NSNumber,
                  directory.withUnsafeFileSystemRepresentation({ path in
                      guard let path else { return false }
                      return access(path, X_OK) == 0
                  }) else { return nil }
            fileNumber = number.uint64Value
            volumeUUID = (try? directory.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        }
    }

    private struct PinFiles: Codable, Hashable {
        let dayDirectory: URL
        let id: UUID
        let hasOriginalText: Bool
        let rootIdentity: HistoryRootIdentity?

        var isHistoryRootAvailable: Bool {
            let root = dayDirectory.deletingLastPathComponent()
            guard let identity = HistoryRootIdentity(at: root) else { return false }
            // Manifests from earlier builds recorded the directory path alone.
            return rootIdentity == nil || rootIdentity == identity
        }

        private var baseURL: URL {
            dayDirectory.appendingPathComponent("pin-\(id.uuidString)")
        }

        var imageURL: URL { baseURL.appendingPathExtension("png") }
        var textURL: URL? { hasOriginalText ? baseURL.appendingPathExtension("txt") : nil }
    }

    private struct Record: Codable {
        let files: PinFiles
        let displayState: PinDisplayState
    }

    private struct Manifest: Codable {
        let records: [Record]
        // Register files before writing. Publishing a saved record takes its files off this list.
        // Retired records and unfinished writes stay listed until their files are removed.
        let cleanupCandidates: Set<PinFiles>

        private enum CodingKeys: String, CodingKey {
            case records
            case cleanupCandidates = "filesToRemove"
        }
    }

    private struct Entry {
        enum Content {
            case pending(image: CGImage, originalText: String?, batch: CloseBatch)
            case stored
        }

        let record: Record
        var content: Content

        var storedRecord: Record? {
            if case .stored = content { return record }
            return nil
        }
    }

    private enum SnapshotReadResult {
        case loaded(PinSnapshot)
        case rootUnavailable
        case unreadable
    }

    private final class Write: @unchecked Sendable {
        let files: PinFiles
        private let queue: DispatchQueue
        // The serial queue owns the write result, including when quit waits for it.
        private var saved = false

        init(files: PinFiles, queue: DispatchQueue) {
            self.files = files
            self.queue = queue
        }

        func start(image: CGImage, originalText: String?, completion: @escaping @MainActor (Write, Bool) -> Void) {
            queue.async {
                let saved = ClosedPinHistory.writeSnapshot(image, originalText: originalText, to: self.files)
                self.saved = saved
                DispatchQueue.main.async { completion(self, saved) }
            }
        }

        func waitForResult() -> Bool {
            queue.sync { saved }
        }
    }

    private let manifestURL: URL?
    private let legacySessions: LegacyPinHistorySessions
    private let writeQueue = DispatchQueue(label: "io.zzusec.airsnip.closed-pin-history", qos: .utility)
    private var entries: [Entry] = []
    private var cleanupCandidates: Set<PinFiles> = []
    private var inFlightWrite: Write?
    var onWriteFailure: (() -> Void)?

    static func manifestURL(for configURL: URL) -> URL {
        configURL.deletingPathExtension().appendingPathExtension("pin-history.json")
    }

    init(configURL: URL?) {
        let manifestURL = configURL.map(Self.manifestURL(for:))
        self.manifestURL = manifestURL
        let legacyRegistryURL = configURL?.deletingPathExtension().appendingPathExtension("pin-history-sessions.json")
        legacySessions = LegacyPinHistorySessions(registryURL: legacyRegistryURL)
        guard let manifestURL, let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        entries = manifest.records.filter { $0.files.dayDirectory.isFileURL }.map { Entry(record: $0, content: .stored) }
        cleanupCandidates = manifest.cleanupCandidates.filter { $0.dayDirectory.isFileURL }
        cleanUnusedFiles()
    }

    var isEmpty: Bool { entries.isEmpty }

    func remember(_ snapshots: [PinSnapshot], limit: Int, historyRoot: URL, closedAt: Date = Date()) {
        guard limit > 0, !snapshots.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let dayDirectory = historyRoot.appendingPathComponent(formatter.string(from: closedAt), isDirectory: true)
        guard (try? Self.ensureHistoryRootExists(historyRoot)) != nil,
              let rootIdentity = HistoryRootIdentity(at: historyRoot) else {
            onWriteFailure?()
            return
        }
        legacySessions.cleanUp(in: historyRoot)
        let batch = CloseBatch()
        let closed = snapshots.suffix(limit).map { snapshot in
            let files = PinFiles(
                dayDirectory: dayDirectory, id: UUID(), hasOriginalText: snapshot.originalText != nil, rootIdentity: rootIdentity
            )
            return Entry(
                record: Record(files: files, displayState: snapshot.displayState),
                content: .pending(image: snapshot.image, originalText: snapshot.originalText, batch: batch)
            )
        }
        let next = entries + closed
        let excess = max(0, next.count - limit)
        guard discard(next.prefix(excess), keeping: Array(next.dropFirst(excess))) else {
            onWriteFailure?()
            return
        }
        writeNext()
    }

    func trim(to limit: Int) -> Bool {
        let excess = entries.count - limit
        guard excess > 0 else { return true }
        return discard(entries.prefix(excess), keeping: Array(entries.dropFirst(excess)))
    }

    func restoreLast() -> (snapshot: PinSnapshot?, skippedUnreadable: Bool) {
        var skippedUnreadable = false
        for index in entries.indices.reversed() {
            let snapshot: PinSnapshot?
            switch Self.readSnapshot(entries[index]) {
            case .loaded(let restored):
                snapshot = restored
            case .rootUnavailable:
                continue
            case .unreadable:
                snapshot = nil
            }

            var next = entries
            next.remove(at: index)
            guard discard(entries[index...index], keeping: next) else {
                onWriteFailure?()
                return (nil, skippedUnreadable)
            }
            if let snapshot { return (snapshot, skippedUnreadable) }
            skippedUnreadable = true
        }
        return (nil, skippedUnreadable)
    }

    func finishPendingWrites() {
        while let write = inFlightWrite {
            completeWrite(write, saved: write.waitForResult())
        }
    }

    nonisolated static func ensureHistoryRootExists(_ historyRoot: URL, attributes: [FileAttributeKey: Any]? = nil) throws {
        let files = FileManager.default
        var isDirectory: ObjCBool = false
        if files.fileExists(atPath: historyRoot.path, isDirectory: &isDirectory), isDirectory.boolValue { return }
        try files.createDirectory(at: historyRoot, withIntermediateDirectories: false, attributes: attributes)
    }

    private func writeNext() {
        guard inFlightWrite == nil else { return }
        while let index = entries.firstIndex(where: { $0.storedRecord == nil }),
              case .pending(let image, let originalText, let batch) = entries[index].content {
            let files = entries[index].record.files
            guard saveAndApply(entries, cleanupCandidates: cleanupCandidates.union([files])) else {
                entries.remove(at: index)
                reportWriteFailure(in: batch)
                continue
            }
            let write = Write(files: files, queue: writeQueue)
            inFlightWrite = write
            write.start(image: image, originalText: originalText) { [weak self] completedWrite, saved in
                self?.completeWrite(completedWrite, saved: saved)
            }
            return
        }
    }

    private func completeWrite(_ write: Write, saved: Bool) {
        // The quit callback may have already finished this write.
        guard write === inFlightWrite else { return }
        inFlightWrite = nil
        let files = write.files
        defer {
            cleanUnusedFiles()
            writeNext()
        }
        // A restore or eviction can consume an entry before its write finishes.
        guard let index = entries.firstIndex(where: { $0.record.files == files }),
              case .pending(_, _, let batch) = entries[index].content else { return }
        if saved {
            var next = entries
            next[index].content = .stored
            if saveAndApply(next, cleanupCandidates: cleanupCandidates.subtracting([files])) { return }
        }
        entries.remove(at: index)
        reportWriteFailure(in: batch)
    }

    private func reportWriteFailure(in batch: CloseBatch) {
        if !batch.reportedWriteFailure {
            batch.reportedWriteFailure = true
            onWriteFailure?()
        }
    }

    private func discard(_ discarded: ArraySlice<Entry>, keeping next: [Entry]) -> Bool {
        let retiredFiles = discarded.compactMap { $0.storedRecord?.files }
        if retiredFiles.isEmpty {
            entries = next
            return true
        }
        guard saveAndApply(next, cleanupCandidates: cleanupCandidates.union(retiredFiles)) else { return false }
        cleanUnusedFiles()
        return true
    }

    func cleanUnusedFiles() {
        let removed = cleanupCandidates.filter { $0 != inFlightWrite?.files && Self.removeFiles($0) }
        if !removed.isEmpty {
            _ = saveAndApply(entries, cleanupCandidates: cleanupCandidates.subtracting(removed))
        }
    }

    private func saveAndApply(_ next: [Entry], cleanupCandidates nextCleanupCandidates: Set<PinFiles>) -> Bool {
        if let manifestURL {
            let manifest = Manifest(records: next.compactMap(\.storedRecord), cleanupCandidates: nextCleanupCandidates)
            do {
                try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            } catch {
                return false
            }
        }
        entries = next
        cleanupCandidates = nextCleanupCandidates
        return true
    }

    private nonisolated static func writeSnapshot(_ image: CGImage, originalText: String?, to files: PinFiles) -> Bool {
        guard files.isHistoryRootAvailable else { return false }
        return autoreleasepool {
            do {
                try ensureHistoryRootExists(files.dayDirectory, attributes: [.posixPermissions: 0o700])
                guard let destination = CGImageDestinationCreateWithURL(files.imageURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
                if let originalText, let textURL = files.textURL {
                    try originalText.write(to: textURL, atomically: false, encoding: .utf8)
                }
                return true
            } catch {
                return false
            }
        }
    }

    private static func readSnapshot(_ entry: Entry) -> SnapshotReadResult {
        let record = entry.record
        switch entry.content {
        case .pending(let image, let originalText, _):
            return .loaded(PinSnapshot(image: image, originalText: originalText, displayState: record.displayState))
        case .stored:
            guard record.files.isHistoryRootAvailable else { return .rootUnavailable }
            if let snapshot = readStoredSnapshot(record) { return .loaded(snapshot) }
            // Keep the record if its directory went offline while reading.
            return record.files.isHistoryRootAvailable ? .unreadable : .rootUnavailable
        }
    }

    private static func readStoredSnapshot(_ record: Record) -> PinSnapshot? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(record.files.imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        var originalText: String?
        if let textURL = record.files.textURL {
            guard let text = try? String(contentsOf: textURL, encoding: .utf8) else { return nil }
            originalText = text
        }
        return PinSnapshot(image: image, originalText: originalText, displayState: record.displayState)
    }

    private nonisolated static func removeFiles(_ files: PinFiles) -> Bool {
        let imageRemoved = removeFile(at: files.imageURL, from: files)
        let textRemoved = files.textURL.map { removeFile(at: $0, from: files) } ?? true
        return imageRemoved && textRemoved
    }

    private nonisolated static func removeFile(at url: URL, from files: PinFiles) -> Bool {
        guard files.isHistoryRootAvailable else { return false }
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            if unlink(path) == 0 { return true }
            guard errno == ENOENT || errno == ENOTDIR else { return false }
            return files.isHistoryRootAvailable
        }
    }
}

private final class LegacyPinHistorySessions {
    private let registryURL: URL?
    private var registeredSessionDirectories: Set<URL> = []

    init(registryURL: URL?) {
        self.registryURL = registryURL
        if let registryURL, let data = try? Data(contentsOf: registryURL),
           let paths = try? JSONDecoder().decode(Set<URL>.self, from: data) {
            registeredSessionDirectories = paths.filter { url in
                url.isFileURL && UUID(uuidString: url.lastPathComponent) != nil
                    && url.deletingLastPathComponent().lastPathComponent == AirSnipConfig.defaultPinHistoryDirectoryName
            }
            removeSessionDirectories(registeredSessionDirectories)
        }
    }

    func cleanUp(in historyRoot: URL) {
        removeSessionDirectories(registeredSessionDirectories.filter {
            $0.deletingLastPathComponent() == historyRoot
        })
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
