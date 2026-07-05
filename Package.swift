// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PDFCompressor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PDFCompressor",
            path: "Sources/PDFCompressor"
        )
    ]
)
