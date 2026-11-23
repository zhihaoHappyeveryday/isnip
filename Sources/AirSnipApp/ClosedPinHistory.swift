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
    var imageOrigin: CGPoint? = nil
}

struct PinSnapshot {
    let image: CGImage
    let originalText: String?
    let displayState: PinDisplayState
    var historyID: UUID? = nil
}

final class ClosedPinHistory: @unchecked Sendable {
    enum Failure {
        case savePin, trim, saveLimit
    }

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
        let baseName: String?
        let hasOriginalText: Bool
        let rootIdentity: HistoryRootIdentity?

        var isHistoryRootAvailable: Bool {
            let root = dayDirectory.deletingLastPathComponent()
            guard let identity = HistoryRootIdentity(at: root) else { return false }
            // Manifests from earlier builds recorded the directory path alone.
            return rootIdentity == nil || rootIdentity == identity
        }

        private var baseURL: URL {
            // Older manifests derived the filename from the record ID.
            dayDirectory.appending(component: baseName ?? "pin-\(id.uuidString)")
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

    // The history queue owns the ordered entries and their manifest. Encoding one PNG at
    // a time on the write queue lets a pending pin still be restored directly from memory.
    private let queue = DispatchQueue(label: "io.zzusec.airsnip.closed-pin-history", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "io.zzusec.airsnip.closed-pin-write", qos: .utility)
    private let manifestURL: URL?
    private var legacySessions: LegacyPinHistorySessions?
    private var limit: Int
    private var entries: [Entry] = []
    private var cleanupCandidates: Set<PinFiles> = []
    private var inFlightWrite: PinFiles?
    private var writeCompletions: [@MainActor () -> Void] = []
    @MainActor var onFailure: ((Failure) -> Void)?

    static func manifestURL(for configURL: URL) -> URL {
        configURL.deletingPathExtension().appendingPathExtension("pin-history.json")
    }

    init(configURL: URL?, limit: Int = AirSnipConfig.defaultPinHistoryLimit) {
        manifestURL = configURL.map(Self.manifestURL(for:))
        self.limit = limit
        queue.async {
            self.load(configURL: configURL)
        }
    }

    private func load(configURL: URL?) {
        let legacyRegistryURL = configURL?.deletingPathExtension().appendingPathExtension("pin-history-sessions.json")
        legacySessions = LegacyPinHistorySessions(registryURL: legacyRegistryURL)
        guard let manifestURL, let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        entries = manifest.records.filter { $0.files.dayDirectory.isFileURL }.map { Entry(record: $0, content: .stored) }
        cleanupCandidates = manifest.cleanupCandidates.filter { $0.dayDirectory.isFileURL }
        cleanUnusedFiles()
        _ = enforceLimit()
    }

    func remember(_ snapshots: [PinSnapshot], historyRoot: URL, closedAt: Date = Date()) {
        guard !snapshots.isEmpty else { return }
        queue.async {
            self.rememberOnQueue(snapshots, historyRoot: historyRoot, closedAt: closedAt)
        }
    }

    private func rememberOnQueue(_ snapshots: [PinSnapshot], historyRoot: URL, closedAt: Date) {
        guard limit > 0 else { return }
        // If consuming a restored pin failed, the original record still covers a concurrent close.
        let existingIDs = Set(entries.map { $0.record.files.id })
        let closedSnapshots = snapshots.filter { $0.historyID.map(existingIDs.contains) != true }.suffix(limit)
        guard !closedSnapshots.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let dayDirectory = historyRoot.appendingPathComponent(formatter.string(from: closedAt), isDirectory: true)
        guard (try? Self.ensureHistoryRootExists(historyRoot)) != nil,
              let rootIdentity = HistoryRootIdentity(at: historyRoot) else {
            report(.savePin)
            return
        }
        legacySessions?.cleanUp(in: historyRoot)

        let timestampName = NameStyle.datetime.formatBaseName(date: closedAt)
        let trackedFiles = entries.map(\.record.files) + Array(cleanupCandidates)
        let reservedNames = Set(trackedFiles.lazy.filter { $0.rootIdentity == rootIdentity }.compactMap(\.baseName))
        let fileManager = FileManager.default
        var suffix = 1
        let batch = CloseBatch()
        let closed = closedSnapshots.map { snapshot in
            var name: String
            var baseURL: URL
            repeat {
                name = suffix == 1 ? timestampName : "\(timestampName)-\(suffix)"
                baseURL = dayDirectory.appending(component: name)
                suffix += 1
            } while reservedNames.contains(name)
                || fileManager.fileExists(atPath: baseURL.appendingPathExtension("png").path)
                || fileManager.fileExists(atPath: baseURL.appendingPathExtension("txt").path)

            let files = PinFiles(
                dayDirectory: dayDirectory, id: UUID(), baseName: name,
                hasOriginalText: snapshot.originalText != nil, rootIdentity: rootIdentity
            )
            return Entry(
                record: Record(files: files, displayState: snapshot.displayState),
                content: .pending(image: snapshot.image, originalText: snapshot.originalText, batch: batch)
            )
        }
        let next = entries + closed
        let excess = max(0, next.count - limit)
        guard discard(next.prefix(excess), keeping: Array(next.dropFirst(excess))) else {
            report(.savePin)
            return
        }
        writeNext()
    }

    func updateLimit(to requested: Int, savingConfig: @escaping (Int) throws -> Void, completion: @escaping @MainActor (Int) -> Void) {
        queue.async {
            self.saveLimitChange(requested, save: savingConfig)
            let applied = self.limit
            Self.onMain { completion(applied) }
        }
    }

    private func saveLimitChange(_ requested: Int, save: (Int) throws -> Void) {
        let previous = limit
        // Retry a previously interrupted trim before allowing older history to become eligible.
        if requested > previous, !enforceLimit() {
            try? save(previous)
            return
        }
        do {
            // Startup also enforces the saved limit if a reduction is interrupted.
            try save(requested)
        } catch {
            report(.saveLimit)
            return
        }
        limit = requested
        if requested < previous, !enforceLimit(), (try? save(previous)) != nil {
            limit = previous
        }
    }

    private func enforceLimit() -> Bool {
        let excess = entries.count - limit
        guard excess > 0 else { return true }
        guard discard(entries.prefix(excess), keeping: Array(entries.dropFirst(excess))) else {
            report(.trim)
            return false
        }
        return true
    }

    func restoreLast(
        if shouldRestore: @escaping @MainActor (_ hasHistory: Bool) -> Bool,
        accept: @escaping @MainActor (PinSnapshot?) -> Bool,
        completion: @escaping @MainActor (_ restored: Bool, _ skippedUnreadable: Bool) -> Void
    ) {
        queue.async {
            let result = self.restoreOnQueue(if: shouldRestore, accept: accept)
            Self.onMain { completion(result.restored, result.skippedUnreadable) }
        }
    }

    private func restoreOnQueue(
        if shouldRestore: @escaping @MainActor (Bool) -> Bool,
        accept: @escaping @MainActor (PinSnapshot?) -> Bool
    ) -> (restored: Bool, skippedUnreadable: Bool) {
        let hasHistory = limit > 0 && !entries.isEmpty
        guard Self.askMain({ shouldRestore(hasHistory) }) else { return (false, false) }
        cleanUnusedFiles()
        guard enforceLimit(), limit > 0 else { return (false, false) }

        var skippedUnreadable = false
        for index in entries.indices.reversed() {
            let read = Self.readSnapshot(entries[index])
            let snapshot: PinSnapshot?
            switch read {
            case .loaded(let restored):
                snapshot = restored
            case .rootUnavailable, .unreadable:
                snapshot = nil
            }

            guard Self.askMain({ accept(snapshot) }) else { return (false, skippedUnreadable) }
            if case .rootUnavailable = read { continue }
            var next = entries
            next.remove(at: index)
            guard discard(entries[index...index], keeping: next) else {
                report(.savePin)
                return (false, skippedUnreadable)
            }
            if snapshot != nil { return (true, skippedUnreadable) }
            skippedUnreadable = true
        }
        return (false, skippedUnreadable)
    }

    func finishPendingWrites(enforcingLimit: Bool = false, completion: @escaping @MainActor () -> Void) {
        queue.async {
            if enforcingLimit { _ = self.enforceLimit() }
            self.writeCompletions.append(completion)
            self.writeNext()
        }
    }

    func retryCleanup() {
        queue.async { self.cleanUnusedFiles() }
    }

    private func report(_ failure: Failure) {
        Self.onMain { self.onFailure?(failure) }
    }

    private static func onMain(_ action: @escaping @MainActor () -> Void) {
        // AppKit can wait for a reply in a modal run loop during termination.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated(action)
        }
    }

    private static func askMain(_ action: @escaping @MainActor () -> Bool) -> Bool {
        var accepted = false
        let work = DispatchWorkItem { accepted = MainActor.assumeIsolated(action) }
        onMain { work.perform() }
        work.wait()
        return accepted
    }

    static func ensureHistoryRootExists(_ historyRoot: URL, attributes: [FileAttributeKey: Any]? = nil) throws {
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
            inFlightWrite = files
            writeQueue.async {
                let saved = Self.writeSnapshot(image, originalText: originalText, to: files)
                self.queue.async { self.completeWrite(files, saved: saved) }
            }
            return
        }
        guard !writeCompletions.isEmpty else { return }
        let completions = writeCompletions
        writeCompletions.removeAll()
        Self.onMain { completions.forEach { $0() } }
    }

    private func completeWrite(_ files: PinFiles, saved: Bool) {
        inFlightWrite = nil
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
            report(.savePin)
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

    private func cleanUnusedFiles() {
        let removed = cleanupCandidates.filter { $0 != inFlightWrite && Self.removeFiles($0) }
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

    private static func writeSnapshot(_ image: CGImage, originalText: String?, to files: PinFiles) -> Bool {
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
            return .loaded(PinSnapshot(image: image, originalText: originalText, displayState: record.displayState, historyID: record.files.id))
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
        return PinSnapshot(image: image, originalText: originalText, displayState: record.displayState, historyID: record.files.id)
    }

    private static func removeFiles(_ files: PinFiles) -> Bool {
        let imageRemoved = removeFile(at: files.imageURL, from: files)
        let textRemoved = files.textURL.map { removeFile(at: $0, from: files) } ?? true
        return imageRemoved && textRemoved
    }

    private static func removeFile(at url: URL, from files: PinFiles) -> Bool {
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
