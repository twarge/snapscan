import AppKit
import Foundation
import Observation

nonisolated struct ScanDocument: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let name: String
    let modified: Date
}

/// The list of scans this app has produced — not a folder listing. Each scan
/// is remembered as URL bookmark data, which tracks the file by identity, so
/// a scan moved or renamed in Finder keeps its place in the list; an entry
/// whose file can no longer be reached (deleted, trashed) is dropped.
@MainActor
@Observable
final class ScanLibrary {
    static let shared = ScanLibrary()

    var documents: [ScanDocument] = []

    nonisolated private struct Entry: Codable {
        let id: UUID
        var bookmark: Data
        let added: Date
    }

    private var entries: [Entry] = []  // newest first
    private var monitor: DispatchSourceFileSystemObject?
    private var monitoredPath: String?

    private let storeURL: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let directory = base.appendingPathComponent("SnapScan", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library.json")
    }()

    init() {
        load()
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ScanLibrary.shared.refresh() }
        }
    }

    /// Records a newly created scan.
    func add(id: UUID, url: URL) {
        guard let bookmark = try? url.bookmarkData() else { return }
        entries.removeAll { $0.id == id }
        entries.insert(Entry(id: id, bookmark: bookmark, added: Date()), at: 0)
        save()
        refresh()
    }

    /// Re-bookmarks a scan after its file was rewritten or renamed by the app
    /// (rewriting replaces the file's identity, so the bookmark must rebind).
    func noteSaved(id: UUID, url: URL) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            add(id: id, url: url)
            return
        }
        if let bookmark = try? url.bookmarkData() {
            entries[index].bookmark = bookmark
            save()
        }
        refresh()
    }

    /// Resolves every bookmark, dropping entries the app can no longer open.
    func refresh() {
        var resolved: [ScanDocument] = []
        var surviving: [Entry] = []
        var changed = false

        for var entry in entries {
            var isStale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: entry.bookmark,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale),
                Self.isPreviewable(url),
                !url.path.contains("/.Trash/")
            else {
                changed = true
                continue
            }
            if isStale, let fresh = try? url.bookmarkData() {
                entry.bookmark = fresh
                changed = true
            }
            surviving.append(entry)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            resolved.append(
                ScanDocument(
                    id: entry.id,
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    modified: values?.contentModificationDate ?? entry.added))
        }

        if changed {
            entries = surviving
            save()
        }
        documents = resolved
    }

    /// Whether the app can actually open this file, not merely see that it
    /// exists. A scan dragged somewhere outside the sandbox's reach still
    /// exists on disk, but nothing can be previewed from it — so it should
    /// leave the list rather than sit there showing an empty pane.
    private static func isPreviewable(_ url: URL) -> Bool {
        // `access(2)`, which this consults, honours the sandbox: a readable
        // path is one this process may genuinely open.
        FileManager.default.isReadableFile(atPath: url.path)
    }

    // MARK: - Change triggers

    /// Watches the scans folder so renames/deletes done in Finder show up
    /// promptly (scans moved elsewhere are still caught on app activation).
    func setMonitoredFolder(_ url: URL) {
        let path = url.path
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if path != monitoredPath {
            monitoredPath = path
            armMonitor(path: path)
        }
        refresh()
    }

    private func armMonitor(path: String) {
        monitor?.cancel()
        monitor = nil
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler {
            Task { @MainActor in ScanLibrary.shared.refresh() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        monitor = source
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
            let stored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = stored
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
