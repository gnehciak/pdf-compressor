import Foundation
import SwiftUI
import PDFKit
import UserNotifications

// MARK: - Model

struct PDFFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var sizeBytes: Int64
    var pageCount: Int
    var detectedDPI: Int?

    enum Status: Equatable {
        case pending
        case working(String)
        case compressed(URL, Int64)
        case keptOriginal(Int64)
        case failed(String)
    }
    var status: Status = .pending

    var name: String { url.lastPathComponent }
    var isFinished: Bool {
        switch status {
        case .compressed, .keptOriginal, .failed: return true
        default: return false
        }
    }
}

struct PreviewState: Equatable {
    var originalPageURL: URL?
    var compressedPageURL: URL?
    var originalPageBytes: Int64 = 0
    var compressedPageBytes: Int64 = 0
    var isLoading = false
    var error: String?
}

// MARK: - App state

@MainActor
final class AppState: ObservableObject {
    @Published var files: [PDFFile] = []
    @Published var selectionID: PDFFile.ID? {
        didSet { if selectionID != oldValue { currentPage = 1; schedulePreview(delay: 0.05) } }
    }
    @Published var settings = CompressionSettings() {
        didSet { if settings != oldValue { schedulePreview() } }
    }
    @Published var currentPage = 1 {
        didSet { if currentPage != oldValue { schedulePreview(delay: 0.1) } }
    }
    @Published var preview = PreviewState()
    @Published var isCompressing = false
    @Published var missingTools = Tools.missingRequired()

    private var previewTask: Task<Void, Never>?
    private var compressTask: Task<Void, Never>?

    var selectedFile: PDFFile? {
        files.first { $0.id == selectionID }
    }

    /// Rough whole-file estimate from the current page's compression ratio.
    var estimatedTotalBytes: Int64? {
        guard let file = selectedFile,
              preview.originalPageBytes > 0, preview.compressedPageBytes > 0 else { return nil }
        let ratio = Double(preview.compressedPageBytes) / Double(preview.originalPageBytes)
        return Int64(Double(file.sizeBytes) * min(ratio, 1.0))
    }

    // MARK: Adding files

    func addFiles(urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        for url in pdfs where !files.contains(where: { $0.url == url }) {
            let doc = PDFDocument(url: url)
            var file = PDFFile(
                url: url,
                sizeBytes: Engine.fileSize(url),
                pageCount: doc?.pageCount ?? 0,
                detectedDPI: nil
            )
            if doc == nil || doc?.isLocked == true {
                file.status = .failed(doc?.isLocked == true ? "Password-protected" : "Not a readable PDF")
            }
            files.append(file)
            let id = file.id
            Task { [weak self] in
                let dpi = await Engine.detectMaxDPI(of: url)
                await MainActor.run {
                    guard let self, let idx = self.files.firstIndex(where: { $0.id == id }) else { return }
                    self.files[idx].detectedDPI = dpi
                }
            }
        }
        if selectionID == nil, let first = files.first(where: { !$0.isFinished }) ?? files.first {
            selectionID = first.id
        }
    }

    func removeFiles(ids: Set<PDFFile.ID>) {
        files.removeAll { ids.contains($0.id) }
        if let sel = selectionID, ids.contains(sel) {
            selectionID = files.first?.id
        }
    }

    func clearFinished() {
        removeFiles(ids: Set(files.filter(\.isFinished).map(\.id)))
    }

    // MARK: Preview

    func schedulePreview(delay: TimeInterval = 0.35) {
        previewTask?.cancel()
        guard let file = selectedFile, file.pageCount > 0 else {
            preview = PreviewState()
            return
        }
        let url = file.url
        let page = max(0, min(currentPage - 1, file.pageCount - 1))
        let settings = self.settings
        preview.isLoading = true
        preview.error = nil
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let result = try await Engine.previewPage(of: url, pageIndex: page, settings: settings)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.preview = PreviewState(
                        originalPageURL: result.originalPageURL,
                        compressedPageURL: result.compressedPageURL,
                        originalPageBytes: result.originalPageBytes,
                        compressedPageBytes: result.compressedPageBytes,
                        isLoading: false
                    )
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.preview.isLoading = false
                    self.preview.error = error.localizedDescription
                }
            }
        }
    }

    // MARK: Compression

    func compressAll() {
        compress(ids: files.filter { !$0.isFinished }.map(\.id))
    }

    func compress(ids: [PDFFile.ID]) {
        guard !isCompressing, !ids.isEmpty else { return }
        isCompressing = true
        let settings = self.settings
        compressTask = Task { [weak self] in
            var succeeded = 0
            var totalSaved: Int64 = 0
            for id in ids {
                guard let self else { return }
                guard !Task.isCancelled else { break }
                guard let file = await MainActor.run(body: { self.files.first { $0.id == id } }) else { continue }
                await self.setStatus(id, .working("Starting…"))
                do {
                    let outcome = try await Engine.compressFile(file.url, settings: settings) { stageText in
                        Task { @MainActor [weak self] in self?.setStatus(id, .working(stageText)) }
                    }
                    switch outcome {
                    case .compressed(let outURL, let newSize):
                        await self.setStatus(id, .compressed(outURL, newSize))
                        succeeded += 1
                        totalSaved += max(0, file.sizeBytes - newSize)
                    case .keptOriginal(let rejectedSize):
                        await self.setStatus(id, .keptOriginal(rejectedSize))
                    }
                } catch is CancellationError {
                    await self.setStatus(id, .pending)
                    break
                } catch {
                    await self.setStatus(id, .failed(error.localizedDescription))
                }
            }
            await MainActor.run { [weak self] in self?.isCompressing = false }
            if succeeded > 0 {
                Self.notify(
                    title: "Compression finished",
                    body: "\(succeeded) file\(succeeded == 1 ? "" : "s") compressed, saved \(formatBytes(totalSaved))."
                )
            }
        }
    }

    func cancelCompression() {
        compressTask?.cancel()
    }

    private func setStatus(_ id: PDFFile.ID, _ status: PDFFile.Status) {
        if let idx = files.firstIndex(where: { $0.id == id }) {
            files[idx].status = status
        }
    }

    static func notify(title: String, body: String) {
        // UNUserNotificationCenter requires a real .app bundle; skip when run as a bare binary.
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
