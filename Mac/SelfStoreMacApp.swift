import AppKit
import SwiftUI

@main
struct SelfStoreMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = Settings.shared

    var body: some Scene {
        MenuBarExtra(isInserted: $settings.showMenuBarIcon) {
            MenuBarView()
        } label: {
            Image(systemName: "shippingbox.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Create the library before the server takes uploads: its setup resets the incoming folder.
            _ = AppLibrary.shared
            ServerController.shared.start()
            Task { await TailscaleManager.shared.sync() }
            Task { await SigningManager.shared.refresh() }
            // Tailscale can come up after us, or its hostname can change; re-check periodically.
            Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
                Task { @MainActor in await TailscaleManager.shared.sync() }
            }
            if let dir = UserDefaults.standard.string(forKey: "debugSnapshotDir") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { DebugSnapshot.run(into: URL(fileURLWithPath: dir)) }
            }
            // With the menu bar icon hidden there is no UI at launch, which is the point;
            // opening the app again (Finder/Spotlight) brings up Settings.
        }
    }

    /// Launching SelfStore again while it runs (e.g. icon hidden) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { WindowManager.shared.show(.settings) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            let ipas = urls.filter { $0.pathExtension.lowercased() == "ipa" }
            guard !ipas.isEmpty else { return }
            WindowManager.shared.show(.library)
            for url in ipas { Task { try? await AppLibrary.shared.importIPA(at: url, move: false, notes: nil) } }
        }
    }
}

@MainActor
final class WindowManager {
    static let shared = WindowManager()
    enum Kind { case library, settings }
    private var windows: [Kind: NSWindow] = [:]

    func show(_ kind: Kind) {
        dismissMenuPanel()
        if let w = windows[kind] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let (title, view, size): (String, AnyView, NSSize) = switch kind {
        case .library: ("SelfStore", AnyView(LibraryView()), NSSize(width: 860, height: 560))
        case .settings: ("SelfStore Settings", AnyView(SettingsView()), NSSize(width: 560, height: 720))
        }
        let hosting = NSHostingController(rootView: view)
        // Let SwiftUI own the window's real toolbar/title instead of drawing its own bar inside the content.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if kind == .library { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.contentViewController = hosting
        w.toolbarStyle = kind == .library ? .unified : .preference
        w.setContentSize(size)
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName(title)
        windows[kind] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// Development aid: `open SelfStore.app --args -debugSnapshotDir /path` writes PNGs of the menu panel and windows.
@MainActor
enum DebugSnapshot {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scheme in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: MenuBarView().background(.regularMaterial))
            host.appearance = NSAppearance(named: scheme)
            host.frame.size = host.fittingSize
            write(host, to: dir.appendingPathComponent("menu-\(scheme == .aqua ? "light" : "dark").png"))
        }
        if let sel = UserDefaults.standard.string(forKey: "debugSelect") { LibrarySelection.shared.selection = sel }
        WindowManager.shared.show(.library)
        WindowManager.shared.show(.settings)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for w in NSApp.windows where w.isVisible && !w.title.isEmpty {
                guard let frameView = w.contentView?.superview else { continue }
                write(frameView, to: dir.appendingPathComponent("window-\(w.title.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")).png"))
            }
        }
    }

    private static func write(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
