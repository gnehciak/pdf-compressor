import AppKit

// Renders the app icon at a given size: macOS-style rounded square,
// red-orange gradient, a white document shape being "squeezed" by arrows.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = size
    // Standard macOS icon inset ≈ 10%
    let inset = s * 0.09
    let squircle = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset),
                                xRadius: s * 0.185, yRadius: s * 0.185)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.93, green: 0.26, blue: 0.21, alpha: 1),
        NSColor(calibratedRed: 0.72, green: 0.11, blue: 0.15, alpha: 1),
    ])!
    gradient.draw(in: squircle, angle: -90)

    // Document
    let docW = s * 0.42, docH = s * 0.52
    let docX = (s - docW) / 2, docY = (s - docH) / 2
    let doc = NSBezierPath(roundedRect: NSRect(x: docX, y: docY, width: docW, height: docH),
                           xRadius: s * 0.03, yRadius: s * 0.03)
    NSColor.white.setFill()
    doc.fill()

    // Text lines on document
    NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
    let lineH = s * 0.025
    for i in 0..<4 {
        let y = docY + docH * 0.62 - CGFloat(i) * s * 0.06
        NSBezierPath(roundedRect: NSRect(x: docX + docW*0.15, y: y, width: docW * 0.7, height: lineH),
                     xRadius: lineH/2, yRadius: lineH/2).fill()
    }
    // "PDF" label
    let label = "PDF" as NSString
    let font = NSFont.systemFont(ofSize: s * 0.085, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.85, green: 0.15, blue: 0.15, alpha: 1),
    ]
    let labelSize = label.size(withAttributes: attrs)
    label.draw(at: NSPoint(x: (s - labelSize.width)/2, y: docY + docH*0.12), withAttributes: attrs)

    // Compression arrows (top-down and bottom-up chevrons)
    NSColor.white.setStroke()
    let arrow = NSBezierPath()
    arrow.lineWidth = s * 0.035
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    let cx = s / 2
    let chevW = s * 0.10
    // top chevron pointing down
    arrow.move(to: NSPoint(x: cx - chevW, y: docY + docH + s*0.10))
    arrow.line(to: NSPoint(x: cx, y: docY + docH + s*0.045))
    arrow.line(to: NSPoint(x: cx + chevW, y: docY + docH + s*0.10))
    // bottom chevron pointing up
    arrow.move(to: NSPoint(x: cx - chevW, y: docY - s*0.10))
    arrow.line(to: NSPoint(x: cx, y: docY - s*0.045))
    arrow.line(to: NSPoint(x: cx + chevW, y: docY - s*0.10))
    arrow.stroke()

    image.unlockFocus()
    return image
}

let outDir = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    let img = drawIcon(size: CGFloat(px))
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { continue }
    rep.size = NSSize(width: px, height: px)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("icons written to \(outDir)")
