import Foundation
import PDFKit
import Vision
import AppKit

/// Adds an invisible, selectable text layer to a PDF using Apple's on-device
/// Vision text recognition — no external OCR dependencies.
enum OCREngine {

    /// Rebuilds `compressed` page by page, overlaying invisible text
    /// recognized from `original` (rendered at high resolution for accuracy).
    /// Pages that already contain text are copied through untouched.
    static func addTextLayer(compressed: URL, original: URL, password: String? = nil) async throws -> URL {
        try await Task.detached(priority: .userInitiated) { () -> URL in
            guard let compDoc = CGPDFDocument(compressed as CFURL), compDoc.numberOfPages > 0 else {
                throw EngineError.pageExtractionFailed
            }
            guard let sourceDoc = PDFDocument(url: original) else {
                throw EngineError.pageExtractionFailed
            }
            if sourceDoc.isLocked {
                guard let password, sourceDoc.unlock(withPassword: password) else {
                    throw EngineError.passwordRequired
                }
            }

            let outURL = Engine.tempPDF()
            var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let ctx = CGContext(outURL as CFURL, mediaBox: &defaultBox, nil) else {
                throw EngineError.pageExtractionFailed
            }

            for pageNum in 1...compDoc.numberOfPages {
                try Task.checkCancellation()
                guard let cgPage = compDoc.page(at: pageNum) else { continue }
                var box = cgPage.getBoxRect(.mediaBox)
                let pageInfo = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
                ctx.beginPDFPage(pageInfo)
                ctx.drawPDFPage(cgPage)

                if let sourcePage = sourceDoc.page(at: pageNum - 1) {
                    let existing = (sourcePage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if existing.isEmpty, let observations = try? recognizeText(on: sourcePage) {
                        drawInvisibleText(observations, pageBox: box, in: ctx)
                    }
                }
                ctx.endPDFPage()
            }
            ctx.closePDF()
            return outURL
        }.value
    }

    /// Runs Vision text recognition on a ~300 DPI render of the page.
    private static func recognizeText(on page: PDFPage) throws -> [VNRecognizedTextObservation] {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 300.0 / 72.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        return request.results ?? []
    }

    /// Draws each recognized line as invisible (mode 3) text positioned over
    /// its bounding box, horizontally scaled to match the box width so
    /// selection and search line up with the page image.
    private static func drawInvisibleText(_ observations: [VNRecognizedTextObservation], pageBox: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.isEmpty else { continue }
            let norm = observation.boundingBox   // normalized, origin bottom-left
            let rect = CGRect(
                x: pageBox.minX + norm.minX * pageBox.width,
                y: pageBox.minY + norm.minY * pageBox.height,
                width: norm.width * pageBox.width,
                height: norm.height * pageBox.height
            )
            guard rect.width > 0.5, rect.height > 0.5 else { continue }

            let fontSize = max(rect.height * 0.85, 1)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(string: candidate.string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
            guard lineWidth > 0 else { continue }

            // Scale glyph advances so the text spans exactly the detected box.
            let sx = rect.width / CGFloat(lineWidth)
            ctx.textMatrix = CGAffineTransform(scaleX: sx, y: 1)
            ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.18)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
}
