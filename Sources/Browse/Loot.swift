import Foundation
import AppKit
import WebKit

// What you have kept, and what is arriving right now. Finished downloads live
// on disk; active ones track `WKDownload.progress` so opening Downloads shows
// live speed/progress, Cancel, and Retry/Resume on failures.

struct Keep: Codable, Identifiable, Equatable {
    var name: String
    var from: String
    var path: String
    var date: Date
    var size: Int64? = nil

    var id: String { path }

    var url: URL { URL(fileURLWithPath: path) }
    var stillThere: Bool { FileManager.default.fileExists(atPath: path) }

    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var formattedSize: String? {
        let bytes: Int64?
        if let size, size >= 0 {
            bytes = size
        } else if stillThere,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let onDisk = attrs[.size] as? Int64 {
            bytes = onDisk
        } else {
            bytes = nil
        }
        guard let bytes, bytes >= 0 else { return nil }
        return Keep.byteFormatter.string(fromByteCount: bytes)
    }
}

@MainActor
final class ActiveDownload: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case failed(String, canResume: Bool)
    }

    let id = UUID()
    weak var download: WKDownload?
    weak var webView: WKWebView?
    let request: URLRequest?
    let from: String

    @Published var name: String
    @Published var destination: URL?
    @Published var completedBytes: Int64 = 0
    @Published var totalBytes: Int64 = -1
    @Published var fraction: Double = 0
    @Published var state: State = .running
    var resumeData: Data?

    private var observations: [NSKeyValueObservation] = []

    init(download: WKDownload, webView: WKWebView?) {
        self.download = download
        self.webView = webView
        self.request = download.originalRequest
        self.from = download.originalRequest?.url?.host() ?? ""
        self.name = download.progress.fileURL?.lastPathComponent
            ?? download.originalRequest?.url?.lastPathComponent
            ?? "Download"
        observe(download)
    }

    deinit {
        observations.removeAll()
    }

    func attach(_ download: WKDownload) {
        observations.removeAll()
        self.download = download
        state = .running
        completedBytes = 0
        totalBytes = -1
        fraction = 0
        observe(download)
    }

    private func observe(_ download: WKDownload) {
        let progress = download.progress
        let sync: (Progress) -> Void = { [weak self] prog in
            let completed = prog.completedUnitCount
            let total = prog.totalUnitCount
            let frac = prog.fractionCompleted
            DispatchQueue.main.async {
                guard let self, self.download === download else { return }
                self.completedBytes = completed
                self.totalBytes = total
                self.fraction = max(0, min(1, frac))
            }
        }
        observations = [
            progress.observe(\.fractionCompleted, options: [.new]) { prog, _ in sync(prog) },
            progress.observe(\.completedUnitCount, options: [.new]) { prog, _ in sync(prog) },
            progress.observe(\.totalUnitCount, options: [.new]) { prog, _ in sync(prog) },
        ]
    }

    func cancel() {
        observations.removeAll()
        download?.cancel { _ in }
    }

    func markFailed(_ error: Error, resumeData: Data?) {
        observations.removeAll()
        download = nil
        // Resuming picks up the same partial file, so a file write failure would
        // fail identically again: offer Retry instead.
        self.resumeData = Self.isFileWriteError(error) ? nil : resumeData
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .failed(message.isEmpty ? "Download failed" : message, canResume: self.resumeData != nil)
    }

    static func isFileWriteError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorCannotCreateFile,
            NSURLErrorCannotOpenFile,
            NSURLErrorCannotWriteToFile,
            NSURLErrorCannotMoveFile,
            NSURLErrorCannotRemoveFile,
        ].contains(nsError.code)
    }

    var progressText: String {
        switch state {
        case .running:
            if totalBytes > 0 {
                return "\(Keep.byteFormatter.string(fromByteCount: completedBytes)) of \(Keep.byteFormatter.string(fromByteCount: totalBytes))"
            } else if completedBytes > 0 {
                return Keep.byteFormatter.string(fromByteCount: completedBytes)
            }
            return "Starting…"
        case .failed(let message, _):
            return message
        }
    }
}

@MainActor
final class Loot: ObservableObject {
    @Published private(set) var kept: [Keep] = []
    @Published private(set) var active: [ActiveDownload] = []

    init() { load() }

    /// Weighted completion fraction across running downloads with known total size.
    var overallProgress: Double? {
        let running = active.filter {
            if case .running = $0.state, $0.totalBytes > 0 { return true }
            return false
        }
        guard !running.isEmpty else { return nil }
        let completed = running.reduce(Int64(0)) { $0 + max(0, $1.completedBytes) }
        let total = running.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        guard total > 0 else { return nil }
        return max(0, min(1, Double(completed) / Double(total)))
    }

    @discardableResult
    func track(_ download: WKDownload, webView: WKWebView?, unlisted: Bool) -> ActiveDownload? {
        guard !unlisted else { return nil }
        if let existing = entry(for: download) { return existing }
        let item = ActiveDownload(download: download, webView: webView)
        active.insert(item, at: 0)
        return item
    }

    func entry(for download: WKDownload) -> ActiveDownload? {
        active.first { $0.download === download }
    }

    func finish(_ download: WKDownload) {
        active.removeAll { $0.download === download }
    }

    func fail(_ download: WKDownload, error: Error, resumeData: Data?) {
        entry(for: download)?.markFailed(error, resumeData: resumeData)
    }

    func dismiss(_ entry: ActiveDownload) {
        active.removeAll { $0.id == entry.id }
    }

    func add(_ keep: Keep) {
        kept.removeAll { $0.path == keep.path }
        kept.insert(keep, at: 0)
        // Fifty is more than anybody scrolls back through.
        if kept.count > 50 { kept.removeLast(kept.count - 50) }
        save()
    }

    func forget(_ keep: Keep) {
        kept.removeAll { $0.id == keep.id }
        save()
    }

    /// Only the list is emptied. Files you asked for are yours, and deleting
    /// them is the Finder's business, not a browser's.
    func forgetAll() {
        kept = []
        save()
    }

    func reveal(_ keep: Keep) {
        NSWorkspace.shared.activateFileViewerSelecting([keep.url])
    }

    func open(_ keep: Keep) {
        NSWorkspace.shared.open(keep.url)
    }

    private static var file: URL { Store.file("downloads.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Loot.file),
              let list = try? JSONDecoder().decode([Keep].self, from: data)
        else { return }
        kept = list
    }

    private func save() {
        let snapshot = kept
        // One after another, the newest last (see Disk).
        Disk.write(Loot.file) { try? JSONEncoder().encode(snapshot) }
    }
}
