import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Menu bar item + popover, done with AppKit directly.
///
/// SwiftUI's `MenuBarExtra(.window)` doesn't resize its window when the content height changes
/// (e.g. connected -> disconnected), leaving a stale square frame around the content. NSPopover with
/// `preferredContentSize` sizing resizes (animated) and draws the native rounded, arrowed chrome.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let store: HeadphoneStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    private let openSettings: () -> Void

    init(store: HeadphoneStore, openSettings: @escaping (SettingsPane?) -> Void) {
        self.store = store
        self.openSettings = { openSettings(nil) }
        super.init()

        let root = PopoverView()
            .environmentObject(store)
            .environment(\.openSettings, OpenSettingsAction { [weak self] pane in
                self?.popover.performClose(nil)
                openSettings(pane)
            })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
        }

        // Refresh the menu bar label whenever the store or the battery preference changes.
        store.objectWillChange
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateButton() }
            .store(in: &cancellables)
        store.$alert
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.showAlert($0) }
            .store(in: &cancellables)
        updateButton()
        if CommandLine.arguments.contains("--show-popover"), let b = item.button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.togglePopover(b) }
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let connected = store.isConnected
        let symbol = connected && store.state?.noise?.mode == .ambient ? "ear" : "headphones"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SoundConnect")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !connected
        if connected, UserDefaults.standard.bool(forKey: Prefs.showBatteryInMenuBar),
           let b = store.state?.primaryBattery {
            button.title = " \(b.level)%"
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            button.title = ""
        }
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = store.state?.modelName ?? "Headphones"
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        store.answerAlert(alert.runModal() == .alertFirstButtonReturn)
    }
}

/// Owns the Settings window: an AppKit NSSplitViewController (real sidebar item with full-height
/// vibrancy, toolbar tracking separator) hosting SwiftUI content in each column. NavigationSplitView in
/// a hand-made NSWindow misaligns its divider against the title bar, so the chrome is AppKit's job.
@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate {
    private var window: NSWindow?
    private let store: HeadphoneStore
    private var paneObserver: NSObjectProtocol?

    init(store: HeadphoneStore) { self.store = store }

    func show(_ pane: SettingsPane?) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane") }
        if window == nil { window = makeWindow() }
        updateTitle()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let sidebar = NSHostingController(rootView: SettingsSidebar().environmentObject(store))
        let detail = NSHostingController(rootView: SettingsDetail().environmentObject(store))
        sidebar.sizingOptions = []
        detail.sizingOptions = []

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = false
        sidebarItem.allowsFullHeightLayout = true
        split.addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 500
        split.addSplitViewItem(detailItem)
        split.splitView.autosaveName = "SoundConnectSettingsSplit"

        let w = NSWindow(contentViewController: split)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // No toolbar band or title-bar hairline: the only line is the sidebar divider, full height, so
        // there's no corner for the two to meet at. The pane title is drawn in the content instead.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.titlebarSeparatorStyle = .none
        w.setContentSize(NSSize(width: 820, height: 620))
        w.contentMinSize = NSSize(width: 740, height: 480)
        w.isReleasedWhenClosed = false
        w.center()
        w.setFrameAutosaveName("SoundConnectSettings")

        paneObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTitle() }
        }
        return w
    }

    private func updateTitle() {
        let pane = SettingsPane(rawValue: UserDefaults.standard.string(forKey: "settingsPane") ?? "") ?? .sound
        if window?.title != pane.title { window?.title = pane.title }
    }

    // Toolbar: just the separator that tracks the sidebar divider, so the title sits over the detail column.
    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }
    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace]
    }
    nonisolated func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }

    /// Debug: draws the whole window (title bar included) to a PNG.
    func snapshot(to url: URL) {
        guard let frameView = window?.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: HeadphoneStore!
    private var sigterm: DispatchSourceSignal?

    func applicationWillTerminate(_ notification: Notification) {
        store?.shutdown()
    }

    @objc func showSettings(_ sender: Any?) { settings?.show(nil) }

    /// Don't resurrect windows from a previous run (an old build's empty Settings window came back this way).
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    private var statusBar: StatusBarController!
    private var settings: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = HeadphoneStore()
        settings = SettingsWindowController(store: store)
        statusBar = StatusBarController(store: store) { [weak self] pane in self?.settings.show(pane) }
        // `kill`/`pkill` (SIGTERM) skips applicationWillTerminate; route it through a normal quit so the
        // Bluetooth channel is released.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
        let d = UserDefaults.standard
        if d.bool(forKey: Prefs.pauseOnRemove), d.bool(forKey: Prefs.pauseOtherApps), !MediaController.mediaKeyAllowed {
            MediaController.requestMediaKeyPermission()
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            settings.show(.sound)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(14)) // let the headphones connect
                for pane in SettingsPane.allCases {
                    self.settings.show(pane)
                    try? await Task.sleep(for: .seconds(1))
                    self.settings.snapshot(to: dir.appendingPathComponent("window-\(pane.rawValue).png"))
                }
            }
        }
    }
}
