import AppKit
import WebKit

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case preparing, downloading, finished, failed(String), cancelled
    }

    let id = UUID()
    let started = Date()
    let sourceURL: URL?
    @Published var fileName: String
    @Published var destination: URL?
    @Published var progress: Double = 0
    @Published var receivedBytes: Int64 = 0
    @Published var expectedBytes: Int64 = -1
    @Published var state: State = .preparing
    weak var download: WKDownload?
    var progressObservation: NSKeyValueObservation?

    init(download: WKDownload) {
        self.download = download
        self.sourceURL = download.originalRequest?.url
        self.fileName = download.originalRequest?.url?.lastPathComponent ?? "Download"
    }

    var isActive: Bool { state == .preparing || state == .downloading }
}

/// Receives WKDownloads from every tab and saves them into ~/Downloads.
@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    @Published private(set) var items: [DownloadItem] = []
    /// Set when a download finishes while the downloads list isn't visible.
    @Published var hasUnseenCompletion = false

    var activeCount: Int { items.filter(\.isActive).count }

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = DownloadItem(download: download)
        item.progressObservation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak item] progress, _ in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            let total = progress.totalUnitCount
            Task { @MainActor in
                guard let item else { return }
                item.progress = fraction
                item.receivedBytes = completed
                item.expectedBytes = total
                if item.state == .preparing { item.state = .downloading }
            }
        }
        items.insert(item, at: 0)
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let destination = DownloadManager.uniqueURL(in: folder, name: suggestedFilename)
        if let item = item(for: download) {
            item.fileName = destination.lastPathComponent
            item.destination = destination
            item.expectedBytes = response.expectedContentLength
            item.state = .downloading
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        item.progress = 1
        item.progressObservation = nil
        hasUnseenCompletion = true
        if let dest = item.destination {
            // Bounce the file in the Downloads stack, as the system does for other downloads.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: dest.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download) else { return }
        item.progressObservation = nil
        if (error as NSError).code == NSURLErrorCancelled {
            item.state = .cancelled
        } else {
            item.state = .failed(error.localizedDescription)
        }
    }

    // MARK: Actions

    func cancel(_ item: DownloadItem) {
        item.download?.cancel { _ in }
        item.state = .cancelled
    }

    func open(_ item: DownloadItem) {
        if let url = item.destination { NSWorkspace.shared.open(url) }
    }

    func reveal(_ item: DownloadItem) {
        if let url = item.destination { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        var candidate = folder.appendingPathComponent(cleaned.isEmpty ? "Download" : cleaned)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}
