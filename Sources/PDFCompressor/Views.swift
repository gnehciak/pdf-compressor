import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Synced PDFKit wrapper

/// Mirrors zoom + scroll between the two side-by-side PDFViews.
@MainActor
final class PDFSyncController {
    private let views = NSHashTable<PDFView>.weakObjects()
    private var syncing = false
    private var observers: [NSObjectProtocol] = []

    func register(_ view: PDFView) {
        views.add(view)
        if let clip = scrollClip(of: view) {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self, weak view] _ in
                guard let view else { return }
                MainActor.assumeIsolated { self?.mirror(from: view) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: view, queue: .main
        ) { [weak self, weak view] _ in
            guard let view else { return }
            MainActor.assumeIsolated { self?.mirror(from: view) }
        })
    }

    private func scrollClip(of view: PDFView) -> NSClipView? {
        for sub in view.subviews {
            if let scroll = sub as? NSScrollView { return scroll.contentView }
        }
        return nil
    }

    private func mirror(from source: PDFView) {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        for case let target? in views.allObjects where target !== source {
            guard target.document != nil else { continue }
            if abs(target.scaleFactor - source.scaleFactor) > 0.001 {
                if source.autoScales == false { target.autoScales = false }
                target.scaleFactor = source.scaleFactor
            }
            if let sourceClip = scrollClip(of: source), let targetClip = scrollClip(of: target) {
                let origin = sourceClip.bounds.origin
                if abs(targetClip.bounds.origin.x - origin.x) > 0.5 || abs(targetClip.bounds.origin.y - origin.y) > 0.5 {
                    targetClip.setBoundsOrigin(origin)
                    (targetClip.superview as? NSScrollView)?.reflectScrolledClipView(targetClip)
                }
            }
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL?
    var sync: PDFSyncController?

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
        sync?.register(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard let url else { view.document = nil; return }
        guard view.document?.documentURL != url else { return }

        // Preserve the user's zoom and scroll position across preview swaps —
        // but only when the new document has the same page geometry (a
        // re-render of the same page). A different file/page resets to fit,
        // otherwise a stale zoom can scroll the view into empty space.
        let oldScale = view.scaleFactor
        let oldPoint = view.currentDestination?.point
        let oldPageSize = view.document?.page(at: 0)?.bounds(for: .mediaBox).size

        view.document = PDFDocument(url: url)
        let newPageSize = view.document?.page(at: 0)?.bounds(for: .mediaBox).size
        let sameGeometry: Bool = {
            guard let oldPageSize, let newPageSize else { return false }
            return abs(oldPageSize.width - newPageSize.width) < 1 &&
                   abs(oldPageSize.height - newPageSize.height) < 1
        }()

        if context.coordinator.userZoomed, sameGeometry, let page = view.document?.page(at: 0) {
            view.autoScales = false
            view.scaleFactor = oldScale
            if let oldPoint {
                view.go(to: PDFDestination(page: page, at: oldPoint))
            }
        } else {
            context.coordinator.userZoomed = false
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
                            if let out = file.compressedURL {
                                ShareLink(item: out) {
                                    Label("Share Compressed", systemImage: "square.and.arrow.up")
                                }
                                Button("Show Compressed in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([out])
                                }
                            }
                            Button("Show Original in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                            }
                            if file.overrideSettings != nil {
                                Button("Remove Custom Settings") {
                                    if let idx = state.files.firstIndex(where: { $0.id == file.id }) {
                                        state.files[idx].overrideSettings = nil
                                        state.schedulePreview()
                                    }
                                }
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
                VStack(alignment: .leading, spacing: 6) {
                    if let saved = state.totalSaved {
                        Label {
                            Text("Saved \(formatBytes(saved.bytes)) across \(saved.files) file(s)")
                                .font(.caption.bold())
                        } icon: {
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                        }
                        .font(.caption)
                    }
                    Button("Clear Finished") { state.clearFinished() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.bar)
            }
        }
    }
}

struct FileRow: View {
    @EnvironmentObject var state: AppState
    let file: PDFFile

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.overrideSettings != nil {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .help("Uses custom settings")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let out = file.compressedURL {
                ShareLink(item: out) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("Share the compressed file")
            }
        }
        .padding(.vertical, 2)
        .onDrag {
            if let out = file.compressedURL, let provider = NSItemProvider(contentsOf: out) {
                return provider
            }
            return NSItemProvider(contentsOf: file.url) ?? NSItemProvider()
        }
    }

    @ViewBuilder private var statusIcon: some View {
        if file.isLocked {
            Image(systemName: "lock.fill").foregroundStyle(.orange)
        } else {
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
    }

    private var subtitle: String {
        var base = formatBytes(file.sizeBytes)
        if file.pageCount > 0 { base += " · \(file.pageCount)p" }
        if let dpi = file.detectedDPI { base += " · \(dpi) DPI" }
        if file.isLocked {
            return base + " · " + String(localized: "Password required")
        }
        switch file.status {
        case .working(let stage):
            return "\(base) · \(stage)"
        case .compressed(_, let newSize):
            return "\(base) → \(formatBytes(newSize)) (\(percentSaved(from: file.sizeBytes, to: newSize)))"
        case .keptOriginal:
            return base + " · " + String(localized: "result was larger — kept original")
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
}

struct PreviewPane: View {
    @EnvironmentObject var state: AppState
    @AppStorage("previewMode") private var previewModeRaw = PreviewMode.slider.rawValue
    @State private var syncController = PDFSyncController()

    private var previewMode: Binding<PreviewMode> {
        Binding(
            get: { PreviewMode(rawValue: previewModeRaw) ?? .slider },
            set: { previewModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            if let file = state.selectedFile, file.isLocked {
                UnlockView(file: file)
            } else if let file = state.selectedFile, file.pageCount > 0 {
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
                title: String(localized: "Original"),
                bytes: state.preview.originalPageBytes,
                url: state.preview.originalPageURL
            )
            Divider()
            paneColumn(
                title: String(localized: "Compressed"),
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
                    Text(formatBytes(state.preview.originalPageBytes) + " / " + String(localized: "page"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let auto = state.preview.autoChosenLabel {
                    Text(auto)
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                } else {
                    Text("Drag the handle to compare")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("Compressed").font(.headline)
                if state.preview.compressedPageBytes > 0 {
                    Text(formatBytes(state.preview.compressedPageBytes) + " / " + String(localized: "page"))
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
            .lineLimit(1)
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
                    Text(formatBytes(bytes) + " / " + String(localized: "page"))
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
                if title == String(localized: "Compressed"), let auto = state.preview.autoChosenLabel {
                    Text(auto)
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            .lineLimit(1)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            PDFKitView(url: url, sync: syncController)
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

// MARK: - Locked file unlock form

struct UnlockView: View {
    @EnvironmentObject var state: AppState
    let file: PDFFile
    @State private var password = ""
    @State private var wrongPassword = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.doc")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("“\(file.name)” is password-protected")
                .font(.headline)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit(unlock)
            if wrongPassword {
                Text("Wrong password — try again")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Unlock") { unlock() }
                .buttonStyle(.borderedProminent)
                .disabled(password.isEmpty)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unlock() {
        wrongPassword = !state.unlock(id: file.id, password: password)
        if wrongPassword { password = "" }
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

                    Rectangle()
                        .fill(.white)
                        .frame(width: 2, height: geo.size.height)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .offset(x: dividerX - 1)

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

                    cornerLabel(String(localized: "Original"), alignment: .topLeading, width: geo.size.width)
                    cornerLabel(String(localized: "Compressed"), alignment: .topTrailing, width: geo.size.width)

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
    @State private var showSavePreset = false
    @State private var presetName = ""

    private var settings: Binding<CompressionSettings> { $state.activeSettings }

    private var currentPresetName: String {
        let all = Preset.builtins + state.userPresets
        return all.first { $0.settings == state.activeSettings }?.name ?? String(localized: "Custom")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                settingsHeader
                presetRow

                if state.selectedFile != nil {
                    Toggle("Custom settings for this file", isOn: Binding(
                        get: { state.selectedFileHasOverride },
                        set: { state.selectedFileHasOverride = $0 }
                    ))
                    .help("Compress this file with different settings than the rest of the batch")
                }

                Picker("Mode", selection: settings.mode) {
                    Text("Quality").tag(CompressionMode.quality)
                    Text("Target size").tag(CompressionMode.targetSize)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if settings.wrappedValue.mode == .targetSize {
                    targetSizeSection
                } else {
                    dpiSection
                    qualitySection
                }

                optionsSection
                Divider()
                outputSection
                compressButton
            }
            .padding(16)
        }
        .background(.background)
        .alert("Save Preset", isPresented: $showSavePreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") {
                state.saveCurrentAsPreset(named: presetName)
                presetName = ""
            }
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text("Saves the current settings as a reusable preset.")
        }
    }

    private var settingsHeader: some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
            Text("Compression").font(.title3.bold())
            Spacer()
        }
    }

    private var presetRow: some View {
        Menu {
            ForEach(Preset.builtins) { preset in
                Button(preset.name) { state.activeSettings = preset.settings }
            }
            if !state.userPresets.isEmpty {
                Divider()
                ForEach(state.userPresets) { preset in
                    Button(preset.name) { state.activeSettings = preset.settings }
                }
                Menu("Delete Preset") {
                    ForEach(state.userPresets) { preset in
                        Button(preset.name, role: .destructive) {
                            state.userPresets.removeAll { $0.id == preset.id }
                        }
                    }
                }
            }
            Divider()
            Button("Save Current as Preset…") { showSavePreset = true }
        } label: {
            HStack {
                Text("Preset:")
                Text(currentPresetName).fontWeight(.medium)
            }
        }
    }

    private var targetSizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Target file size").font(.headline)
            HStack {
                TextField("Size", value: settings.targetSizeMB, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("MB")
            }
            Text("Automatically finds the best quality that fits under this size.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let auto = state.preview.autoChosenLabel {
                Label(auto, systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
    }

    private var dpiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Target resolution").font(.headline)
            if let dpi = state.selectedFile?.detectedDPI {
                Label("Original images: \(dpi) DPI", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.wrappedValue.targetDPI >= dpi {
                    Label("Source is already ≤ target — only JPEG quality shrinks this file. Lower the target DPI for more.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Picker("DPI", selection: settings.targetDPI) {
                if !CompressionSettings.dpiPresets.contains(where: { $0.dpi == settings.wrappedValue.targetDPI }) {
                    Text("Custom — \(settings.wrappedValue.targetDPI) DPI").tag(settings.wrappedValue.targetDPI)
                }
                ForEach(CompressionSettings.dpiPresets, id: \.dpi) { preset in
                    Text(preset.label).tag(preset.dpi)
                }
            }
            .labelsHidden()
            DeferredSlider(value: settings.targetDPI, range: 10...300) {
                "\($0) DPI"
            }
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("JPEG quality").font(.headline)
            Picker("Quality", selection: settings.jpegQuality) {
                if !CompressionSettings.qualityPresets.contains(where: { $0.q == settings.wrappedValue.jpegQuality }) {
                    Text("Custom — \(settings.wrappedValue.jpegQuality)").tag(settings.wrappedValue.jpegQuality)
                }
                ForEach(CompressionSettings.qualityPresets, id: \.q) { preset in
                    Text(preset.label).tag(preset.q)
                }
            }
            .labelsHidden()
            DeferredSlider(value: settings.jpegQuality, range: 5...95) {
                String(localized: "Quality \($0) — lower is smaller")
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Options").font(.headline)
            Toggle("Convert to grayscale", isOn: settings.grayscale)
            Toggle("Make searchable (OCR)", isOn: settings.makeSearchable)
            Text("Adds an invisible text layer with Apple's on-device text recognition, so scans become selectable and searchable.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Strip metadata", isOn: settings.stripMetadata)
            Text("Removes title, author and other document info before sharing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Extra optimization pass", isOn: settings.extraOptimize)
                .disabled(!Tools.hasOCRmyPDF)
            Text(Tools.hasOCRmyPDF
                 ? String(localized: "Runs ocrmypdf --optimize after downsampling. Slower, but often much smaller.")
                 : String(localized: "Install ocrmypdf (brew install ocrmypdf) to enable the extra optimization pass."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output").font(.headline)
            Toggle("Replace original file", isOn: $state.replaceOriginal)
            Text(state.replaceOriginal
                 ? String(localized: "The original is moved to the Trash and the compressed file takes its place.")
                 : String(localized: "Saved next to the original as *_compressed.pdf. If the result isn’t smaller, the original is kept."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var compressButton: some View {
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
}
