import Foundation
import PDFKit

// MARK: - Settings

enum CompressionMode: String, Codable, Equatable {
    case quality
    case targetSize
}

struct CompressionSettings: Equatable, Codable {
    var mode: CompressionMode = .quality
    var targetDPI: Int = 72
    var jpegQuality: Int = 40
    var targetSizeMB: Double = 10
    var grayscale: Bool = false
    var extraOptimize: Bool = true
    var optimizeLevel: Int = 3
    var makeSearchable: Bool = false
    var stripMetadata: Bool = false

    static let dpiPresets: [(dpi: Int, label: String)] = [
        (300, String(localized: "300 — Print quality")),
        (200, String(localized: "200 — High quality")),
        (150, String(localized: "150 — Good quality")),
        (100, String(localized: "100 — Decent")),
        (72,  String(localized: "72 — Screen quality")),
        (50,  String(localized: "50 — Blurry but readable")),
        (36,  String(localized: "36 — Pixelated")),
        (25,  String(localized: "25 — Heavy artifacts")),
        (15,  String(localized: "15 — Barely readable")),
        (10,  String(localized: "10 — Practically destroyed")),
    ]

    static let qualityPresets: [(q: Int, label: String)] = [
        (90, String(localized: "90 — High quality")),
        (70, String(localized: "70 — Good")),
        (50, String(localized: "50 — Medium")),
        (40, String(localized: "40 — Low")),
        (25, String(localized: "25 — Very low")),
        (15, String(localized: "15 — Lowest")),
    ]

    /// Quality ladder used by target-size search, best quality first.
    static let ladder: [(dpi: Int, q: Int)] = [
        (300, 90), (250, 80), (200, 70), (150, 60), (150, 45),
        (120, 45), (100, 40), (72, 40), (72, 28), (50, 25),
        (36, 18), (25, 12), (15, 8), (10, 5),
    ]

    func atLadder(_ index: Int) -> CompressionSettings {
        var s = self
        s.mode = .quality
        s.targetDPI = Self.ladder[index].dpi
        s.jpegQuality = Self.ladder[index].q
        return s
    }

    var targetSizeBytes: Int64 { Int64(targetSizeMB * 1_000_000) }
}

// MARK: - Presets

struct Preset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var settings: CompressionSettings

    private static func make(_ name: String, _ configure: (inout CompressionSettings) -> Void) -> Preset {
        var s = CompressionSettings()
        configure(&s)
        return Preset(name: name, settings: s)
    }

    static let builtins: [Preset] = [
        make(String(localized: "Email — under 10 MB")) { $0.mode = .targetSize; $0.targetSizeMB = 10 },
        make(String(localized: "High quality — 150 DPI")) { $0.targetDPI = 150; $0.jpegQuality = 70 },
        make(String(localized: "Screen — 100 DPI")) { $0.targetDPI = 100; $0.jpegQuality = 50 },
        make(String(localized: "Compact scan — 72 DPI")) { $0.targetDPI = 72; $0.jpegQuality = 40 },
        make(String(localized: "Tiny — 36 DPI")) { $0.targetDPI = 36; $0.jpegQuality = 25 },
    ]
}

// MARK: - Shell plumbing

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum EngineError: LocalizedError {
    case toolNotFound(String)
    case commandFailed(tool: String, status: Int32, stderr: String)
    case pageExtractionFailed
    case passwordRequired
    case cancelled

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let t):
            return String(localized: "\(t) not found. Install it with Homebrew.")
        case .commandFailed(let tool, let status, let stderr):
            let detail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            return "\(tool) failed (exit \(status)). \(detail)"
        case .pageExtractionFailed:
            return String(localized: "Could not extract page for preview.")
        case .passwordRequired:
            return String(localized: "Password required")
        case .cancelled:
            return String(localized: "Cancelled.")
        }
    }
}

enum Tools {
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// Ghostscript shipped inside the app bundle (Contents/Resources/gs/).
    static var bundledGS: String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let path = res.appendingPathComponent("gs/bin/gs").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var bundledGSShare: String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let path = res.appendingPathComponent("gs/share").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func find(_ name: String) -> String? {
        if name == "gs", let bundled = bundledGS { return bundled }
        for dir in searchDirs {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Names of required tools that are missing (ocrmypdf is optional;
    /// Ghostscript only when neither bundled nor installed).
    static func missingRequired() -> [String] {
        find("gs") == nil ? ["ghostscript"] : []
    }

    static var hasOCRmyPDF: Bool { find("ocrmypdf") != nil }
}

// MARK: - Engine

enum Engine {

    static var tempDir: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFCompressor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func tempPDF() -> URL {
        tempDir.appendingPathComponent(UUID().uuidString + ".pdf")
    }

    @discardableResult
    static func run(_ toolPath: String, _ args: [String]) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = args
        // ocrmypdf needs a sane PATH to find its helpers (gs, jbig2, pngquant…)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Tools.searchDirs.joined(separator: ":") + ":" + (env["PATH"] ?? "")
        // The bundled Ghostscript loads its init files/fonts/ICC profiles
        // from the app bundle rather than a Homebrew prefix.
        if toolPath == Tools.bundledGS, let share = Tools.bundledGSShare {
            env["GS_LIB"] = ["Resource/Init", "lib", "fonts", "iccprofiles", "Resource/Font", "Resource/CMap"]
                .map { share + "/" + $0 }
                .joined(separator: ":")
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: ShellResult(
                        status: process.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    ))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: Metadata

    /// Highest effective DPI among embedded images, read natively via CGPDF.
    /// Assumes an image spans its page (true for scans), so this is a lower
    /// bound for images drawn smaller than the page.
    static func detectMaxDPI(of url: URL, password: String? = nil) async -> Int? {
        await Task.detached(priority: .utility) { () -> Int? in
            guard let doc = CGPDFDocument(url as CFURL) else { return nil }
            if doc.isEncrypted, !doc.isUnlocked, let password {
                _ = password.withCString { doc.unlockWithPassword($0) }
            }
            guard doc.isUnlocked, doc.numberOfPages > 0 else { return nil }
            var maxPPI = 0.0
            for pageNum in 1...doc.numberOfPages {
                guard let page = doc.page(at: pageNum) else { continue }
                let media = page.getBoxRect(.mediaBox)
                let pageWidthIn = media.width / 72.0
                let pageHeightIn = media.height / 72.0
                guard pageWidthIn > 0, pageHeightIn > 0, let dict = page.dictionary else { continue }
                var resources: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let res = resources else { continue }
                var xObjects: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(res, "XObject", &xObjects), let xo = xObjects else { continue }
                CGPDFDictionaryApplyBlock(xo, { _, value, _ in
                    var streamRef: CGPDFStreamRef?
                    guard CGPDFObjectGetValue(value, .stream, &streamRef), let stream = streamRef,
                          let sd = CGPDFStreamGetDictionary(stream) else { return true }
                    var subtype: UnsafePointer<CChar>?
                    guard CGPDFDictionaryGetName(sd, "Subtype", &subtype), let s = subtype,
                          String(cString: s) == "Image" else { return true }
                    var width: CGPDFInteger = 0
                    var height: CGPDFInteger = 0
                    CGPDFDictionaryGetInteger(sd, "Width", &width)
                    CGPDFDictionaryGetInteger(sd, "Height", &height)
                    let ppi = max(Double(width) / pageWidthIn, Double(height) / pageHeightIn)
                    if ppi.isFinite { maxPPI = max(maxPPI, ppi) }
                    return true
                }, nil)
            }
            return maxPPI >= 10 ? Int(maxPPI.rounded()) : nil
        }.value
    }

    static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
    }

    // MARK: Ghostscript downsample pass

    /// Maps JPEG quality (0–100, higher = better) to a Distiller QFactor
    /// (higher = worse) by interpolating between known-good anchor points.
    static func qFactor(forQuality quality: Int) -> Double {
        let anchors: [(q: Int, f: Double)] = [
            (5, 3.0), (15, 2.4), (25, 1.8), (40, 1.3),
            (50, 0.9), (70, 0.5), (90, 0.2), (95, 0.1),
        ]
        if quality <= anchors.first!.q { return anchors.first!.f }
        if quality >= anchors.last!.q { return anchors.last!.f }
        for i in 1..<anchors.count where quality <= anchors[i].q {
            let (q0, f0) = anchors[i - 1]
            let (q1, f1) = anchors[i]
            let t = Double(quality - q0) / Double(q1 - q0)
            return f0 + t * (f1 - f0)
        }
        return 0.9
    }

    static func ghostscript(input: URL, output: URL, settings: CompressionSettings, password: String? = nil) async throws {
        guard let gs = Tools.find("gs") else { throw EngineError.toolNotFound("ghostscript") }
        var args = [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.4",
            "-dNOPAUSE", "-dQUIET", "-dBATCH",
            "-dDownsampleColorImages=true",
            "-dColorImageResolution=\(settings.targetDPI)",
            "-dDownsampleGrayImages=true",
            "-dGrayImageResolution=\(settings.targetDPI)",
            "-dDownsampleMonoImages=true",
            "-dMonoImageResolution=\(settings.targetDPI)",
            // pdfwrite ignores -dJPEGQ; JPEG quality must come in as a
            // distiller QFactor with automatic filter selection disabled.
            "-dAutoFilterColorImages=false",
            "-dAutoFilterGrayImages=false",
            "-dColorImageFilter=/DCTEncode",
            "-dGrayImageFilter=/DCTEncode",
            // Without this, source JPEGs that aren't downsampled are copied
            // through verbatim and the quality setting has no effect at all
            // (typical for photo scans whose effective DPI is already low).
            "-dPassThroughJPEGImages=false",
            // Default threshold is 1.5×, which skips downsampling e.g.
            // 100 DPI images when targeting 72. Downsample whenever above target.
            "-dColorImageDownsampleThreshold=1.0",
            "-dGrayImageDownsampleThreshold=1.0",
            "-dMonoImageDownsampleThreshold=1.0",
        ]
        if settings.grayscale {
            args += ["-sColorConversionStrategy=Gray", "-dProcessColorModel=/DeviceGray"]
        } else {
            // Re-encoding images through their source ICC profile can produce
            // corrupt ICCBased colorspaces (blank pages in Quartz/Poppler),
            // e.g. iPhone Display P3 scans. Convert to plain RGB instead.
            args += ["-sColorConversionStrategy=RGB"]
        }
        if let password, !password.isEmpty {
            args += ["-sPDFPassword=\(password)"]
        }
        let qf = String(format: "%.2f", qFactor(forQuality: settings.jpegQuality))
        let imageDict = "<< /QFactor \(qf) /Blend 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >>"
        args += [
            "-sOutputFile=\(output.path)",
            "-c", "<< /ColorImageDict \(imageDict) /GrayImageDict \(imageDict) >> setdistillerparams",
            "-f", input.path,
        ]

        let result = try await run(gs, args)
        guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw EngineError.commandFailed(tool: "Ghostscript", status: result.status, stderr: result.stderr)
        }
    }

    // MARK: ocrmypdf optimize pass

    static func optimize(input: URL, output: URL, settings: CompressionSettings) async throws {
        guard let ocrmypdf = Tools.find("ocrmypdf") else { throw EngineError.toolNotFound("ocrmypdf") }
        let args = [
            "--optimize", "\(settings.optimizeLevel)",
            "--jpeg-quality", "\(settings.jpegQuality)",
            "--png-quality", "\(settings.jpegQuality)",
            "--pdfa-image-compression", "jpeg",
            "--skip-text",
            input.path, output.path,
        ]
        let result = try await run(ocrmypdf, args)
        guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw EngineError.commandFailed(tool: "ocrmypdf", status: result.status, stderr: result.stderr)
        }
    }

    // MARK: Target-size search

    /// Finds the highest-quality ladder entry whose Ghostscript output fits
    /// `targetBytes` (binary search — sizes decrease along the ladder).
    /// Returns the output and the settings used; falls back to the most
    /// aggressive entry if nothing fits.
    static func searchToTarget(
        _ input: URL,
        targetBytes: Int64,
        base: CompressionSettings,
        password: String?,
        stage: @escaping @Sendable (String) -> Void
    ) async throws -> (url: URL, settings: CompressionSettings) {
        var lo = 0
        var hi = CompressionSettings.ladder.count - 1
        var best: (URL, CompressionSettings)?
        while lo <= hi {
            try Task.checkCancellation()
            let mid = (lo + hi) / 2
            let candidate = base.atLadder(mid)
            stage(String(localized: "Trying \(candidate.targetDPI) DPI · quality \(candidate.jpegQuality)…"))
            let out = tempPDF()
            try await ghostscript(input: input, output: out, settings: candidate, password: password)
            if fileSize(out) <= targetBytes {
                if let (oldURL, _) = best { try? FileManager.default.removeItem(at: oldURL) }
                best = (out, candidate)
                hi = mid - 1
            } else {
                try? FileManager.default.removeItem(at: out)
                lo = mid + 1
            }
        }
        if let best { return best }
        // Nothing fit — use the most aggressive settings.
        let fallback = base.atLadder(CompressionSettings.ladder.count - 1)
        stage(String(localized: "Trying \(fallback.targetDPI) DPI · quality \(fallback.jpegQuality)…"))
        let out = tempPDF()
        try await ghostscript(input: input, output: out, settings: fallback, password: password)
        return (out, fallback)
    }

    // MARK: Metadata stripping

    /// Clears the document info dictionary (title, author, producer, …).
    static func stripMetadata(at url: URL) {
        guard let doc = PDFDocument(url: url) else { return }
        doc.documentAttributes = [:]
        doc.write(to: url)
    }

    // MARK: Full-file compression

    enum Outcome {
        case compressed(URL, Int64)     // output url, new size
        case keptOriginal(Int64)        // compressed size that was rejected
    }

    /// Runs the full pipeline. Writes `<name>_compressed.pdf` next to the
    /// original (or replaces the original, moving it to the Trash). Keeps the
    /// original if the result is not smaller — unless OCR was requested, in
    /// which case the searchable output is the point.
    static func compressFile(
        _ input: URL,
        settings: CompressionSettings,
        password: String? = nil,
        replaceOriginal: Bool = false,
        stage: @escaping @Sendable (String) -> Void
    ) async throws -> Outcome {
        let originalSize = fileSize(input)
        var work: URL

        if settings.mode == .targetSize {
            (work, _) = try await searchToTarget(
                input, targetBytes: settings.targetSizeBytes,
                base: settings, password: password, stage: stage
            )
        } else {
            stage(String(localized: "Downsampling…"))
            work = tempPDF()
            try await ghostscript(input: input, output: work, settings: settings, password: password)
        }
        try Task.checkCancellation()

        if settings.extraOptimize && Tools.hasOCRmyPDF {
            stage(String(localized: "Optimizing…"))
            let optimized = tempPDF()
            do {
                try await optimize(input: work, output: optimized, settings: settings)
                try? FileManager.default.removeItem(at: work)
                work = optimized
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Optimizer failure is non-fatal — keep the Ghostscript output.
            }
        }
        try Task.checkCancellation()

        if settings.makeSearchable {
            stage(String(localized: "Recognizing text…"))
            let searchable = try await OCREngine.addTextLayer(compressed: work, original: input, password: password)
            try? FileManager.default.removeItem(at: work)
            work = searchable
        }
        try Task.checkCancellation()

        if settings.stripMetadata {
            stage(String(localized: "Stripping metadata…"))
            stripMetadata(at: work)
        }

        let newSize = fileSize(work)
        let keepEvenIfLarger = settings.makeSearchable
        if !keepEvenIfLarger && (newSize >= originalSize || newSize == 0) {
            try? FileManager.default.removeItem(at: work)
            return .keptOriginal(newSize)
        }

        if replaceOriginal {
            try FileManager.default.trashItem(at: input, resultingItemURL: nil)
            try FileManager.default.moveItem(at: work, to: input)
            return .compressed(input, newSize)
        }
        let output = uniqueOutputURL(for: input)
        try FileManager.default.moveItem(at: work, to: output)
        return .compressed(output, newSize)
    }

    static func uniqueOutputURL(for input: URL) -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base)_compressed.pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_compressed \(n).pdf")
            n += 1
        }
        return candidate
    }

    // MARK: Preview (single page)

    struct PagePreview {
        let originalPageURL: URL
        let compressedPageURL: URL
        let originalPageBytes: Int64
        let compressedPageBytes: Int64
    }

    private static func previewTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFCompressorPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func extractPage(of document: URL, pageIndex: Int, password: String?) throws -> URL {
        guard let doc = PDFDocument(url: document) else { throw EngineError.pageExtractionFailed }
        if doc.isLocked {
            guard let password, doc.unlock(withPassword: password) else { throw EngineError.passwordRequired }
        }
        guard pageIndex < doc.pageCount, let page = doc.page(at: pageIndex) else {
            throw EngineError.pageExtractionFailed
        }
        let onePage = PDFDocument()
        onePage.insert(page, at: 0)
        let url = previewTempDir().appendingPathComponent("orig-\(UUID().uuidString).pdf")
        guard onePage.write(to: url) else { throw EngineError.pageExtractionFailed }
        return url
    }

    /// Extracts one page and runs the Ghostscript pass on it so the preview
    /// shows real downsampling + JPEG artifacts at the chosen settings.
    static func previewPage(of document: URL, pageIndex: Int, settings: CompressionSettings, password: String? = nil) async throws -> PagePreview {
        let originalPageURL = try extractPage(of: document, pageIndex: pageIndex, password: password)
        try Task.checkCancellation()
        let compressedPageURL = previewTempDir().appendingPathComponent("comp-\(UUID().uuidString).pdf")
        try await ghostscript(input: originalPageURL, output: compressedPageURL, settings: settings)
        return PagePreview(
            originalPageURL: originalPageURL,
            compressedPageURL: compressedPageURL,
            originalPageBytes: fileSize(originalPageURL),
            compressedPageBytes: fileSize(compressedPageURL)
        )
    }

    /// Target-size preview: probes the ladder on a single page, estimating the
    /// whole-file size from the page ratio, and returns the chosen settings.
    static func previewAutoTarget(
        of document: URL,
        pageIndex: Int,
        base: CompressionSettings,
        fullFileSize: Int64,
        password: String? = nil
    ) async throws -> (preview: PagePreview, chosen: CompressionSettings) {
        let originalPageURL = try extractPage(of: document, pageIndex: pageIndex, password: password)
        let originalPageBytes = fileSize(originalPageURL)
        guard originalPageBytes > 0 else { throw EngineError.pageExtractionFailed }

        let target = base.targetSizeBytes
        var lo = 0
        var hi = CompressionSettings.ladder.count - 1
        var best: (URL, Int64, CompressionSettings)?
        while lo <= hi {
            try Task.checkCancellation()
            let mid = (lo + hi) / 2
            let candidate = base.atLadder(mid)
            let out = previewTempDir().appendingPathComponent("comp-\(UUID().uuidString).pdf")
            try await ghostscript(input: originalPageURL, output: out, settings: candidate)
            let pageBytes = fileSize(out)
            let estimated = Int64(Double(fullFileSize) * Double(pageBytes) / Double(originalPageBytes))
            if estimated <= target {
                if let (oldURL, _, _) = best { try? FileManager.default.removeItem(at: oldURL) }
                best = (out, pageBytes, candidate)
                hi = mid - 1
            } else {
                try? FileManager.default.removeItem(at: out)
                lo = mid + 1
            }
        }
        let chosen: (URL, Int64, CompressionSettings)
        if let best {
            chosen = best
        } else {
            let fallback = base.atLadder(CompressionSettings.ladder.count - 1)
            let out = previewTempDir().appendingPathComponent("comp-\(UUID().uuidString).pdf")
            try await ghostscript(input: originalPageURL, output: out, settings: fallback)
            chosen = (out, fileSize(out), fallback)
        }
        let preview = PagePreview(
            originalPageURL: originalPageURL,
            compressedPageURL: chosen.0,
            originalPageBytes: originalPageBytes,
            compressedPageBytes: chosen.1
        )
        return (preview, chosen.2)
    }

    static func cleanPreviewTemp() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PDFCompressorPreview")
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Formatting helpers

func formatBytes(_ bytes: Int64) -> String {
    let fmt = ByteCountFormatter()
    fmt.countStyle = .file
    return fmt.string(fromByteCount: bytes)
}

func percentSaved(from old: Int64, to new: Int64) -> String {
    guard old > 0 else { return "" }
    let pct = 100.0 * (1.0 - Double(new) / Double(old))
    return String(format: "−%.0f%%", pct)
}
