import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var state: AppState?
    private var pendingURLs: [URL] = []

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        NSApp.activate(ignoringOtherApps: true)
        flushPending()
    }

    // "Compress with PDF Compressor" Services menu entry (NSMessage: compressPDFs).
    @objc func compressPDFs(_ pboard: NSPasteboard, userData: String,
                            error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        pendingURLs.append(contentsOf: urls)
        flushPending()
    }

    // Files opened via Finder / dock drop / "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        flushPending()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.cleanPreviewTemp()
    }

    func flushPending() {
        guard let state, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        Task { @MainActor in state.addFiles(urls: urls) }
    }
}

@main
struct PDFCompressorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .onAppear {
                    delegate.state = state
                    delegate.flushPending()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDFs…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.pdf]
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        state.addFiles(urls: panel.urls)
                    }
                }
                .keyboardShortcut("o")
            }
        }
    }
}
