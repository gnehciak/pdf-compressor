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
    var isLocked = false
    var password: String?
    var overrideSettings: CompressionSettings?

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
    var compressedURL: URL? {
        if case .compressed(let url, _) = status { return url }
        return nil
    }
}

struct PreviewState: Equatable {
    var originalPageURL: URL?
    var compressedPageURL: URL?
    var originalPageBytes: Int64 = 0
    var compressedPageBytes: Int64 = 0
    var autoChosenLabel: String?      // "72 DPI · quality 40" in target-size mode
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
    @Published var replaceOriginal = UserDefaults.standard.bool(forKey: "replaceOriginal") {
        didSet { UserDefaults.standard.set(replaceOriginal, forKey: "replaceOriginal") }
    }
    @Published var userPresets: [Preset] = AppState.loadUserPresets() {
        didSet { Self.saveUserPresets(userPresets) }
    }

    private var previewTask: Task<Void, Never>?
    private var compressTask: Task<Void, Never>?

    var selectedFile: PDFFile? {
        files.first { $0.id == selectionID }
    }

    func effectiveSettings(for file: PDFFile) -> CompressionSettings {
        file.overrideSettings ?? settings
    }

    /// Rough whole-file estimate from the current page's compression ratio.
    var estimatedTotalBytes: Int64? {
        guard let file = selectedFile,
              preview.originalPageBytes > 0, preview.compressedPageBytes > 0 else { return nil }
        let ratio = Double(preview.compressedPageBytes) / Double(preview.originalPageBytes)
        return Int64(Double(file.sizeBytes) * min(ratio, 1.0))
    }

    /// Batch summary across finished files.
    var totalSaved: (files: Int, bytes: Int64)? {
        var count = 0
        var bytes: Int64 = 0
        for file in files {
            if case .compressed(_, let newSize) = file.status {
                count += 1
                bytes += max(0, file.sizeBytes - newSize)
            }
        }
        return count > 0 ? (count, bytes) : nil
    }

    // MARK: Presets

    private static func loadUserPresets() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: "userPresets"),
              let presets = try? JSONDecoder().decode([Preset].self, from: data) else { return [] }
        return presets
    }

    private static func saveUserPresets(_ presets: [Preset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: "userPresets")
        }
    }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        userPresets.removeAll { $0.name == trimmed }
        userPresets.append(Preset(name: trimmed, settings: activeSettings))
    }

    /// The settings currently being edited (per-file override or global).
    var activeSettings: CompressionSettings {
        get {
            if let file = selectedFile, let override = file.overrideSettings { return override }
            return settings
        }
        set {
            if let id = selectionID,
               let idx = files.firstIndex(where: { $0.id == id }),
               files[idx].overrideSettings != nil {
                files[idx].overrideSettings = newValue
                schedulePreview()
            } else {
                settings = newValue
            }
        }
    }

    var selectedFileHasOverride: Bool {
        get { selectedFile?.overrideSettings != nil }
        set {
            guard let id = selectionID, let idx = files.firstIndex(where: { $0.id == id }) else { return }
            files[idx].overrideSettings = newValue ? settings : nil
            schedulePreview()
        }
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
            if doc == nil {
                file.status = .failed(String(localized: "Not a readable PDF"))
            } else if doc?.isLocked == true {
                file.isLocked = true
            }
            files.append(file)
            if file.isLocked == false, file.isFinished == false {
                reloadMetadata(for: file.id)
            }
        }
        if selectionID == nil, let first = files.first(where: { !$0.isFinished }) ?? files.first {
            selectionID = first.id
        }
    }

    private func reloadMetadata(for id: PDFFile.ID) {
        guard let file = files.first(where: { $0.id == id }) else { return }
        let url = file.url
        let password = file.password
        Task { [weak self] in
            let dpi = await Engine.detectMaxDPI(of: url, password: password)
            await MainActor.run {
                guard let self, let idx = self.files.firstIndex(where: { $0.id == id }) else { return }
                self.files[idx].detectedDPI = dpi
            }
        }
    }

    /// Attempts to unlock a password-protected file. Returns false if the
    /// password is wrong.
    func unlock(id: PDFFile.ID, password: String) -> Bool {
        guard let idx = files.firstIndex(where: { $0.id == id }) else { return false }
        guard let doc = PDFDocument(url: files[idx].url), doc.unlock(withPassword: password) else {
            return false
        }
        files[idx].password = password
        files[idx].isLocked = false
        files[idx].pageCount = doc.pageCount
        reloadMetadata(for: id)
        if selectionID == id { schedulePreview(delay: 0.05) }
        return true
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
        guard let file = selectedFile, file.pageCount > 0, !file.isLocked else {
            preview = PreviewState()
            return
        }
        let url = file.url
        let page = max(0, min(currentPage - 1, file.pageCount - 1))
        let effective = effectiveSettings(for: file)
        let password = file.password
        let fullSize = file.sizeBytes
        preview.isLoading = true
        preview.error = nil
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                let result: Engine.PagePreview
                var autoLabel: String?
                if effective.mode == .targetSize {
                    let (p, chosen) = try await Engine.previewAutoTarget(
                        of: url, pageIndex: page, base: effective,
                        fullFileSize: fullSize, password: password
                    )
                    result = p
                    autoLabel = String(localized: "Auto: \(chosen.targetDPI) DPI · quality \(chosen.jpegQuality)")
                } else {
                    result = try await Engine.previewPage(of: url, pageIndex: page, settings: effective, password: password)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.preview = PreviewState(
                        originalPageURL: result.originalPageURL,
                        compressedPageURL: result.compressedPageURL,
                        originalPageBytes: result.originalPageBytes,
                        compressedPageBytes: result.compressedPageBytes,
                        autoChosenLabel: autoLabel,
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
        let replace = replaceOriginal
        compressTask = Task { [weak self] in
            var succeeded = 0
            var totalSavedBytes: Int64 = 0
            for id in ids {
                guard let self else { return }
                guard !Task.isCancelled else { break }
                guard let file = await MainActor.run(body: { self.files.first { $0.id == id } }) else { continue }
                if file.isLocked {
                    await self.setStatus(id, .failed(String(localized: "Password required — select the file and enter it")))
                    continue
                }
                let fileSettings = await MainActor.run(body: { self.effectiveSettings(for: file) })
                await self.setStatus(id, .working(String(localized: "Starting…")))
                do {
                    let outcome = try await Engine.compressFile(
                        file.url,
                        settings: fileSettings,
                        password: file.password,
                        replaceOriginal: replace
                    ) { stageText in
                        Task { @MainActor [weak self] in self?.setStatus(id, .working(stageText)) }
                    }
                    switch outcome {
                    case .compressed(let outURL, let newSize):
                        await self.setStatus(id, .compressed(outURL, newSize))
                        succeeded += 1
                        totalSavedBytes += max(0, file.sizeBytes - newSize)
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
                let saved = formatBytes(totalSavedBytes)
                Self.notify(
                    title: String(localized: "Compression finished"),
                    body: String(localized: "\(succeeded) file(s) compressed, saved \(saved).")
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
