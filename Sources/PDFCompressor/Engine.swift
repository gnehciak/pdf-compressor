import Foundation
import PDFKit

// MARK: - Settings

struct CompressionSettings: Equatable {
    var targetDPI: Int = 72
    var jpegQuality: Int = 40
    var grayscale: Bool = false
    var extraOptimize: Bool = true   // second pass through ocrmypdf --optimize
    var optimizeLevel: Int = 3

    static let dpiPresets: [(dpi: Int, label: String)] = [
        (300, "300 — Print quality"),
        (200, "200 — High quality"),
        (150, "150 — Good quality"),
        (100, "100 — Decent"),
        (72,  "72 — Screen quality"),
        (50,  "50 — Blurry but readable"),
        (36,  "36 — Pixelated"),
        (25,  "25 — Heavy artifacts"),
        (15,  "15 — Barely readable"),
        (10,  "10 — Practically destroyed"),
    ]

    static let qualityPresets: [(q: Int, label: String)] = [
        (90, "90 — High quality"),
        (70, "70 — Good"),
        (50, "50 — Medium"),
        (40, "40 — Low"),
        (25, "25 — Very low"),
        (15, "15 — Lowest"),
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
    case cancelled

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let t):
            return "\(t) not found. Install it with: brew install \(t == "pdfimages" ? "poppler" : t)"
        case .commandFailed(let tool, let status, let stderr):
            let detail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            return "\(tool) failed (exit \(status)). \(detail)"
        case .pageExtractionFailed:
            return "Could not extract page for preview."
        case .cancelled:
            return "Cancelled."
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
    static func detectMaxDPI(of url: URL) async -> Int? {
        await Task.detached(priority: .utility) { () -> Int? in
            guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return nil }
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

    static func ghostscript(input: URL, output: URL, settings: CompressionSettings) async throws {
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
        ]
        if settings.grayscale {
            args += ["-sColorConversionStrategy=Gray", "-dProcessColorModel=/DeviceGray"]
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

    // MARK: Full-file compression

    enum Outcome {
        case compressed(URL, Int64)     // output url, new size
        case keptOriginal(Int64)        // compressed size that was rejected
    }

    /// Runs the full pipeline. Writes `<name>_compressed.pdf` next to the original
    /// (uniqued if that name is taken). Keeps the original if the result is not smaller.
    static func compressFile(
        _ input: URL,
        settings: CompressionSettings,
        stage: @escaping @Sendable (String) -> Void
    ) async throws -> Outcome {
        let originalSize = fileSize(input)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFCompressor", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let temp = tempDir.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: temp) }

        stage("Downsampling…")
        try await ghostscript(input: input, output: temp, settings: settings)
        try Task.checkCancellation()

        var resultURL = temp
        if settings.extraOptimize && Tools.hasOCRmyPDF {
            stage("Optimizing…")
            let optimized = tempDir.appendingPathComponent(UUID().uuidString + ".pdf")
            do {
                try await optimize(input: temp, output: optimized, settings: settings)
                resultURL = optimized
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Optimizer failure is non-fatal — fall back to the Ghostscript output.
                resultURL = temp
            }
        }
        try Task.checkCancellation()

        let newSize = fileSize(resultURL)
        if newSize >= originalSize || newSize == 0 {
            if resultURL != temp { try? FileManager.default.removeItem(at: resultURL) }
            return .keptOriginal(newSize)
        }

        let output = uniqueOutputURL(for: input)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: resultURL, to: output)
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

    /// Extracts one page and runs the Ghostscript pass on it so the preview shows
    /// real downsampling + JPEG artifacts at the chosen settings.
    static func previewPage(of document: URL, pageIndex: Int, settings: CompressionSettings) async throws -> PagePreview {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFCompressorPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        guard let doc = PDFDocument(url: document),
              pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex) else {
            throw EngineError.pageExtractionFailed
        }
        let onePage = PDFDocument()
        onePage.insert(page, at: 0)
        let originalPageURL = tempDir.appendingPathComponent("orig-\(UUID().uuidString).pdf")
        guard onePage.write(to: originalPageURL) else { throw EngineError.pageExtractionFailed }

        try Task.checkCancellation()
        let compressedPageURL = tempDir.appendingPathComponent("comp-\(UUID().uuidString).pdf")
        try await ghostscript(input: originalPageURL, output: compressedPageURL, settings: settings)

        return PagePreview(
            originalPageURL: originalPageURL,
            compressedPageURL: compressedPageURL,
            originalPageBytes: fileSize(originalPageURL),
            compressedPageBytes: fileSize(compressedPageURL)
        )
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
