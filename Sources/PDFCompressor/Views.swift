import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - PDFKit wrapper

struct PDFKitView: NSViewRepresentable {
    let url: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var view: PDFView?
        var userZoomed = false

        func observe(_ view: PDFView) {
            self.view = view
            NotificationCenter.default.addObserver(
                self, selector: #selector(scaleChanged),
                name: .PDFViewScaleChanged, object: view
            )
        }

        // Once the user pinches away from fit, turn autoScales off so PDFKit
        // stops snapping the zoom back on every layout pass.
        @objc func scaleChanged() {
            guard let view, view.document != nil else { return }
            let isAtFit = abs(view.scaleFactor - view.scaleFactorForSizeToFit) < 0.01
            if !isAtFit && view.autoScales {
                view.autoScales = false
            }
            userZoomed = !isAtFit
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.backgroundColor = .windowBackgroundColor
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 12
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let url else { view.document = nil; return }
        guard view.document?.documentURL != url else { return }

        // Preserve the user's zoom and scroll position across preview swaps
        // (the page geometry is identical, only the encoding changed).
        let keepZoom = context.coordinator.userZoomed
        let oldScale = view.scaleFactor
        let oldPoint = view.currentDestination?.point

        view.document = PDFDocument(url: url)
        if keepZoom, let page = view.document?.page(at: 0) {
            view.autoScales = false
            view.scaleFactor = oldScale
            if let oldPoint {
                view.go(to: PDFDestination(page: page, at: oldPoint))
            }
        } else {
            view.autoScales = true
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false
    @State private var showSettings = true

    var body: some View {
        NavigationSplitView {
            FileListView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 280)
        } detail: {
            PreviewPane()
                .inspector(isPresented: $showSettings) {
                    SettingsPanel()
                        .inspectorColumnWidth(min: 250, ideal: 270, max: 300)
                }
        }
        .frame(minWidth: 920, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openPanel()
                } label: {
                    Label("Add PDFs", systemImage: "plus")
                }
                .help("Add PDF files")

                if state.isCompressing {
                    Button(role: .cancel) {
                        state.cancelCompression()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        state.compressAll()
                    } label: {
                        Label("Compress All", systemImage: "arrow.down.circle.fill")
                    }
                    .disabled(state.files.allSatisfy(\.isFinished) || state.files.isEmpty)
                    .help("Compress all pending files")
                }

                Button {
                    showSettings.toggle()
                } label: {
                    Label("Settings", systemImage: "sidebar.trailing")
                }
                .help("Show or hide compression settings")
            }
        }
        .alert("Missing tools", isPresented: .constant(!state.missingTools.isEmpty)) {
            Button("Quit") { NSApp.terminate(nil) }
        } message: {
            Text("Install the required tools first:\n\nbrew install \(state.missingTools.joined(separator: " "))")
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            state.addFiles(urls: panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in state.addFiles(urls: [url]) }
                }
            }
        }
        return found
    }
}

// MARK: - Sidebar

struct FileListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: $state.selectionID) {
            Section("Files") {
                ForEach(state.files) { file in
                    FileRow(file: file)
                        .tag(file.id)
                        .contextMenu {
                            if case .compressed(let outURL, _) = file.status {
                                Button("Show Compressed in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([outURL])
                                }
                            }
                            Button("Show Original in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                            Divider()
                            Button("Remove", role: .destructive) {
                                state.removeFiles(ids: [file.id])
                            }
                        }
                }
            }
        }
        .overlay {
            if state.files.isEmpty {
                ContentUnavailableView(
                    "No PDFs",
                    systemImage: "doc.badge.plus",
                    description: Text("Drop PDF files anywhere in the window\nor click + to add them.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if state.files.contains(where: \.isFinished) {
                HStack {
                    Button("Clear Finished") { state.clearFinished() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    Spacer()
                }
                .padding(8)
                .background(.bar)
            }
        }
    }
}

struct FileRow: View {
    let file: PDFFile

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusIcon: some View {
        switch file.status {
        case .pending:
            Image(systemName: "doc.fill").foregroundStyle(.secondary)
        case .working:
            ProgressView().controlSize(.small)
        case .compressed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .keptOriginal:
            Image(systemName: "equal.circle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var subtitle: String {
        var base = formatBytes(file.sizeBytes)
        if file.pageCount > 0 { base += " · \(file.pageCount)p" }
        if let dpi = file.detectedDPI { base += " · \(dpi) DPI" }
        switch file.status {
        case .working(let stage):
            return "\(base) · \(stage)"
        case .compressed(_, let newSize):
            return "\(base) → \(formatBytes(newSize)) (\(percentSaved(from: file.sizeBytes, to: newSize)))"
        case .keptOriginal:
            return "\(base) · result was larger — kept original"
        case .failed(let message):
            return message
        default:
            return base
        }
    }
}

// MARK: - Preview pane

enum PreviewMode: String, CaseIterable, Identifiable {
    case sideBySide
    case slider
    var id: String { rawValue }
    var label: String { self == .sideBySide ? "Side by Side" : "Slider" }
}

struct PreviewPane: View {
    @EnvironmentObject var state: AppState
    @AppStorage("previewMode") private var previewModeRaw = PreviewMode.slider.rawValue

    private var previewMode: Binding<PreviewMode> {
        Binding(
            get: { PreviewMode(rawValue: previewModeRaw) ?? .slider },
            set: { previewModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            if let file = state.selectedFile, file.pageCount > 0 {
                VStack(spacing: 0) {
                    if previewMode.wrappedValue == .sideBySide {
                        sideBySide
                    } else {
                        sliderComparison
                    }
                    Divider()
                    footer(file: file)
                }
            } else {
                ContentUnavailableView(
                    "No preview",
                    systemImage: "eye.slash",
                    description: Text("Select a PDF in the sidebar to preview compression.")
                )
            }
        }
    }

    private var savingsBadgeText: String? {
        state.preview.originalPageBytes > 0 && state.preview.compressedPageBytes > 0
            ? percentSaved(from: state.preview.originalPageBytes, to: state.preview.compressedPageBytes)
            : nil
    }

    private var sideBySide: some View {
        HStack(spacing: 0) {
            paneColumn(
                title: "Original",
                bytes: state.preview.originalPageBytes,
                url: state.preview.originalPageURL
            )
            Divider()
            paneColumn(
                title: "Compressed",
                bytes: state.preview.compressedPageBytes,
                url: state.preview.compressedPageURL,
                savings: savingsBadgeText
            )
        }
        .overlay { statusOverlay }
    }

    private var sliderComparison: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Original").font(.headline)
                if state.preview.originalPageBytes > 0 {
                    Text(formatBytes(state.preview.originalPageBytes) + " / page")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Drag the handle to compare")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Compressed").font(.headline)
                if state.preview.compressedPageBytes > 0 {
                    Text(formatBytes(state.preview.compressedPageBytes) + " / page")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let savings = savingsBadgeText {
                    Text(savings)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.gradient, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            ComparisonSliderView(
                originalURL: state.preview.originalPageURL,
                compressedURL: state.preview.compressedPageURL
            )
        }
        .overlay { statusOverlay }
    }

    @ViewBuilder private var statusOverlay: some View {
        if state.preview.isLoading {
            ZStack {
                Color.black.opacity(0.05)
                ProgressView("Rendering preview…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        } else if let error = state.preview.error {
            ContentUnavailableView(
                "Preview failed",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .background(.background)
        }
    }

    private func paneColumn(title: String, bytes: Int64, url: URL?, savings: String? = nil) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if bytes > 0 {
                    Text(formatBytes(bytes) + " / page")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let savings {
                    Text(savings)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.gradient, in: Capsule())
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            PDFKitView(url: url)
        }
    }

    private func footer(file: PDFFile) -> some View {
        HStack {
            HStack(spacing: 4) {
                Button {
                    state.currentPage = max(1, state.currentPage - 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(state.currentPage <= 1)

                Text("Page \(state.currentPage) of \(file.pageCount)")
                    .font(.callout)
                    .monospacedDigit()
                    .frame(minWidth: 110)

                Button {
                    state.currentPage = min(file.pageCount, state.currentPage + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(state.currentPage >= file.pageCount)
            }
            .buttonStyle(.borderless)

            Spacer()

            Picker("View", selection: previewMode) {
                Image(systemName: "rectangle.split.2x1").tag(PreviewMode.sideBySide)
                    .help("Side by side")
                Image(systemName: "rectangle.leadinghalf.filled").tag(PreviewMode.slider)
                    .help("Comparison slider")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            if let estimate = state.estimatedTotalBytes {
                Text("Estimated full file: \(formatBytes(file.sizeBytes)) → ~\(formatBytes(estimate))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(.bar)
    }
}

// MARK: - Comparison slider

/// Before/after view: original page on the left of a draggable divider,
/// compressed page on the right. Pinch to zoom, drag to pan while zoomed,
/// double-click to reset.
struct ComparisonSliderView: View {
    let originalURL: URL?
    let compressedURL: URL?

    @State private var position: CGFloat = 0.5
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var basePanOffset: CGSize = .zero
    @State private var isPanning: Bool?
    @State private var originalImage: NSImage?
    @State private var compressedImage: NSImage?

    var body: some View {
        GeometryReader { geo in
            if let orig = originalImage, let comp = compressedImage,
               orig.size.width > 0, orig.size.height > 0,
               geo.size.width > 0, geo.size.height > 0 {
                let fit = min(geo.size.width / orig.size.width, geo.size.height / orig.size.height)
                let w = orig.size.width * fit
                let h = orig.size.height * fit
                let dividerX = geo.size.width * position

                ZStack(alignment: .topLeading) {
                    pageLayer(orig, container: geo.size, w: w, h: h)
                    pageLayer(comp, container: geo.size, w: w, h: h)
                        .mask(alignment: .topLeading) {
                            Rectangle().padding(.leading, dividerX)
                        }

                    // Divider line spanning the viewport
                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: geo.size.height)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .offset(x: dividerX - 1)

                    // Drag handle
                    Circle()
                        .fill(.white)
                        .frame(width: 30, height: 30)
                        .overlay {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.black)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .position(x: dividerX, y: geo.size.height / 2)

                    cornerLabel("Original", alignment: .topLeading, width: geo.size.width)
                    cornerLabel("Compressed", alignment: .topTrailing, width: geo.size.width)

                    if zoom > 1.01 {
                        Text("\(Int(zoom * 100))% — double-click to reset")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(8)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomTrailing)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture(container: geo.size, dividerX: dividerX, w: w, h: h))
                .simultaneousGesture(magnifyGesture(w: w, h: h))
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) { resetZoom() }
                }
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: [originalURL, compressedURL]) {
            await loadImages()
        }
    }

    /// One page image, fitted then zoomed/panned, centered in the container.
    private func pageLayer(_ image: NSImage, container: CGSize, w: CGFloat, h: CGFloat) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: w, height: h)
            .scaleEffect(zoom)
            .offset(panOffset)
            .position(x: container.width / 2, y: container.height / 2)
            .frame(width: container.width, height: container.height)
    }

    /// Below 1× everything resets; drags near the divider always move the
    /// divider; other drags pan when zoomed in, else move the divider too.
    private func dragGesture(container: CGSize, dividerX: CGFloat, w: CGFloat, h: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if isPanning == nil {
                    let nearDivider = abs(value.startLocation.x - dividerX) < 24
                    isPanning = zoom > 1.01 && !nearDivider
                }
                if isPanning == true {
                    panOffset = clampedOffset(
                        CGSize(width: basePanOffset.width + value.translation.width,
                               height: basePanOffset.height + value.translation.height),
                        w: w, h: h, container: container
                    )
                } else {
                    position = min(max(value.location.x / container.width, 0), 1)
                }
            }
            .onEnded { _ in
                basePanOffset = panOffset
                isPanning = nil
            }
    }

    private func magnifyGesture(w: CGFloat, h: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(baseZoom * value, 1), 8)
            }
            .onEnded { _ in
                baseZoom = zoom
                if zoom <= 1.01 { resetZoom() }
            }
    }

    private func clampedOffset(_ offset: CGSize, w: CGFloat, h: CGFloat, container: CGSize) -> CGSize {
        let maxX = max(0, (w * zoom - container.width) / 2 + 40)
        let maxY = max(0, (h * zoom - container.height) / 2 + 40)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    private func resetZoom() {
        zoom = 1
        baseZoom = 1
        panOffset = .zero
        basePanOffset = .zero
    }

    @ViewBuilder
    private func cornerLabel(_ text: String, alignment: Alignment, width: CGFloat) -> some View {
        // Hide the label on the side that's been swiped away
        let visible = alignment == .topLeading ? position > 0.12 : position < 0.88
        if visible {
            Text(text)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(8)
                .frame(width: width, alignment: alignment)
        }
    }

    private func loadImages() async {
        let origURL = originalURL
        let compURL = compressedURL
        let images = await Task.detached(priority: .userInitiated) {
            (Self.renderPage(origURL), Self.renderPage(compURL))
        }.value
        originalImage = images.0
        compressedImage = images.1
    }

    /// Rasterizes page 1 of the PDF at ~1800px wide so JPEG/downsampling
    /// artifacts are faithfully visible.
    private static func renderPage(_ url: URL?) -> NSImage? {
        guard let url,
              let doc = PDFDocument(url: url),
              let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0 else { return nil }
        let scale = 1800 / bounds.width
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        return page.thumbnail(of: size, for: .mediaBox)
    }
}

// MARK: - Settings panel

/// Slider that shows a live value label while dragging but only commits the
/// binding (and thus triggers preview regeneration) when the thumb is released.
struct DeferredSlider: View {
    @Binding var value: Int
    let range: ClosedRange<Double>
    let caption: (Int) -> String

    @State private var local = 0.0
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Slider(value: $local, in: range) { editing in
                isEditing = editing
                if !editing { value = Int(local.rounded()) }
            }
            Text(caption(Int(local.rounded())))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .onAppear { local = Double(value) }
        .onChange(of: value) { _, newValue in
            if !isEditing { local = Double(newValue) }
        }
    }
}

struct SettingsPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsHeader

                VStack(alignment: .leading, spacing: 8) {
                    Text("Target resolution").font(.headline)
                    if let dpi = state.selectedFile?.detectedDPI {
                        Label("Original images: \(dpi) DPI", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("DPI", selection: $state.settings.targetDPI) {
                        if !CompressionSettings.dpiPresets.contains(where: { $0.dpi == state.settings.targetDPI }) {
                            Text("Custom — \(state.settings.targetDPI) DPI").tag(state.settings.targetDPI)
                        }
                        ForEach(CompressionSettings.dpiPresets, id: \.dpi) { preset in
                            Text(preset.label).tag(preset.dpi)
                        }
                    }
                    .labelsHidden()
                    DeferredSlider(value: $state.settings.targetDPI, range: 10...300) {
                        "\($0) DPI"
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("JPEG quality").font(.headline)
                    Picker("Quality", selection: $state.settings.jpegQuality) {
                        if !CompressionSettings.qualityPresets.contains(where: { $0.q == state.settings.jpegQuality }) {
                            Text("Custom — \(state.settings.jpegQuality)").tag(state.settings.jpegQuality)
                        }
                        ForEach(CompressionSettings.qualityPresets, id: \.q) { preset in
                            Text(preset.label).tag(preset.q)
                        }
                    }
                    .labelsHidden()
                    DeferredSlider(value: $state.settings.jpegQuality, range: 5...95) {
                        "Quality \($0) — lower is smaller"
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Options").font(.headline)
                    Toggle("Convert to grayscale", isOn: $state.settings.grayscale)
                    Toggle("Extra optimization pass", isOn: $state.settings.extraOptimize)
                        .disabled(!Tools.hasOCRmyPDF)
                    Text(Tools.hasOCRmyPDF
                         ? "Runs ocrmypdf --optimize \(state.settings.optimizeLevel) after downsampling. Slower, but often much smaller."
                         : "Install ocrmypdf (brew install ocrmypdf) to enable the extra optimization pass.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Output").font(.headline)
                    Text("Saved next to the original as *_compressed.pdf. If the result isn’t smaller, the original is kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if state.isCompressing {
                    Button(role: .cancel) {
                        state.cancelCompression()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                } else {
                    Button {
                        state.compressAll()
                    } label: {
                        Label("Compress All", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(state.files.isEmpty || state.files.allSatisfy(\.isFinished))
                }
            }
            .padding(16)
        }
        .background(.background)
    }

    private var settingsHeader: some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
            Text("Compression").font(.title3.bold())
            Spacer()
        }
    }
}
