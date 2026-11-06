import AppKit
import Combine
import GifMakerCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let preferences = Preferences.shared
    let store: RecordingStore
    let capture: CaptureController
    private(set) var captureWindow: CaptureWindowController!
    private(set) var editors: [UUID: EditorWindowController] = [:]

    private var settingsWindow: NSWindow?
    private let hotKey = GlobalHotKey()
    /// Whether the system accepted the current record shortcut.
    private(set) var isHotKeyRegistered = false
    private var isTerminating = false
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private let captureMenu = NSMenu(title: "Capture")
    private var subscriptions: Set<AnyCancellable> = []
    #if DEBUG
        private var automation: Automation?
    #endif

    override init() {
        var directory = RecordingStore.defaultDirectory
        #if DEBUG
            // Lets development runs keep their recordings away from the real library.
            if let override = ProcessInfo.processInfo.environment["GIFMAKER_DATA_DIR"] {
                directory = URL(fileURLWithPath: override, isDirectory: true)
            }
        #endif
        store = RecordingStore(directory: directory)
        capture = CaptureController(store: store, preferences: preferences)
        super.init()
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        captureWindow = CaptureWindowController(capture: capture, store: store, preferences: preferences)
        captureWindow.onOpenRecording = { [weak self] in self?.openEditor(for: $0) }
        captureWindow.onShowSettings = { [weak self] in self?.showSettings() }

        capture.regionProvider = { [weak self] in self?.captureWindow.captureRegion() }
        capture.onFinished = { [weak self] recording in
            guard let self, self.preferences.openEditorAfterRecording, !self.isTerminating else { return }
            self.openEditor(for: recording)
        }
        capture.onFailure = { [weak self] error in self?.showError(error) }
        capture.onPermissionNeeded = { ScreenRecordingPermission.showAlert() }

        setUpStatusItem()

        hotKey.handler = { [weak self] in self?.toggleRecording() }
        preferences.$hotKey
            .sink { [weak self] combo in self?.registerHotKey(combo) }
            .store(in: &subscriptions)
        capture.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.updateStatusItem(for: state) }
            .store(in: &subscriptions)
        // Close the editor of any recording that gets deleted.
        store.$recordings
            .sink { [weak self] recordings in
                guard let self else { return }
                let remaining = Set(recordings.map(\.id))
                for (id, editor) in self.editors where !remaining.contains(id) {
                    editor.close()
                }
            }
            .store(in: &subscriptions)

        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification, NSWindow.willCloseNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ] {
            center.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.captureWindow.yield(to: NSApp.isActive ? NSApp.mainWindow : nil) }
                .store(in: &subscriptions)
        }

        captureWindow.show()
        NSApp.activate(ignoringOtherApps: true)

        #if DEBUG
            automation = Automation.startIfRequested(app: self)
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        captureWindow.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard capture.state != .idle else { return .terminateNow }
        // Finish the recording in progress first, then quit.
        isTerminating = true
        capture.$state
            .sink { [weak self] state in
                switch state {
                case .recording: self?.capture.stop()
                case .idle: NSApp.reply(toApplicationShouldTerminate: true)
                case .starting, .finishing: break
                }
            }
            .store(in: &subscriptions)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        for editor in editors.values { editor.model.tearDown() }
    }

    // MARK: Actions

    func toggleRecording() {
        if capture.state == .idle, !captureWindow.isVisible {
            captureWindow.show()
        }
        capture.toggle()
    }

    func openEditor(for recording: Recording) {
        if let existing = editors[recording.id] {
            existing.show()
            return
        }
        guard let current = store.recording(withID: recording.id) else { return }
        let controller = EditorWindowController(recording: current, store: store)
        let id = recording.id
        controller.onClose = { [weak self] in
            // Let the window finish closing before its controller is released.
            DispatchQueue.main.async { self?.editors[id] = nil }
        }
        editors[id] = controller
        controller.show()
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "GIF Maker Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView(
                    preferences: preferences, store: store,
                    onClearCaptures: { [weak self] in self?.captureWindow.confirmClearCaptures() }))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recording could not be completed"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func registerHotKey(_ combo: KeyCombo?) {
        isHotKeyRegistered = hotKey.register(combo) && combo != nil
        guard !isHotKeyRegistered, let combo else { return }
        let alert = NSAlert()
        alert.messageText = "\(combo.displayString) can't be used"
        alert.informativeText = "Another app is already using this shortcut. Choose a different one in Settings."
        alert.runModal()
    }

    // MARK: Menus

    private var recordMenuTitle: String {
        let action = capture.state == .recording ? "Stop Recording" : "Start Recording"
        guard let combo = preferences.hotKey else { return action }
        return "\(action)  (\(combo.displayString))"
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About GIF Maker", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { [weak self] in self?.showSettings() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide GIF Maker", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit GIF Maker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            ClosureMenuItem(title: "Show Capture Window", keyEquivalent: "n") { [weak self] in
                self?.captureWindow.show()
            })
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: fileMenu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: editMenu)

        captureMenu.delegate = self
        main.addItem(submenu: captureMenu)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu: windowMenu)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.toolTip = "GIF Maker"
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusMenu.delegate = self
        statusItem = item
        updateStatusItem(for: capture.state)
    }

    /// While recording, the menu bar icon becomes a stop button.
    private func updateStatusItem(for state: CaptureState) {
        guard let item = statusItem, let button = item.button else { return }
        let recording = state == .recording || state == .finishing
        button.image = NSImage(
            systemSymbolName: recording ? "stop.circle.fill" : "record.circle",
            accessibilityDescription: recording ? "Stop recording" : "GIF Maker")
        button.contentTintColor = recording ? .systemRed : nil
        item.menu = recording ? nil : statusMenu
    }

    @objc private func statusItemClicked() {
        if capture.state == .recording { capture.stop() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let idle = capture.state == .idle

        let record = ClosureMenuItem(title: recordMenuTitle) { [weak self] in self?.toggleRecording() }
        record.isEnabled = idle || capture.state == .recording
        menu.addItem(record)

        if menu === captureMenu {
            let size = ClosureMenuItem(title: "Set Capture Size…") { [weak self] in
                guard let self else { return }
                self.captureWindow.show()
                if let size = CaptureSizePrompt.run(
                    current: self.captureWindow.glassRect.size, minimum: CaptureWindowController.minimumGlassSize)
                {
                    self.captureWindow.setGlassSize(size)
                }
            }
            size.isEnabled = idle
            menu.addItem(size)
            menu.addItem(.separator())
            let clear = ClosureMenuItem(title: "Clear Captures…") { [weak self] in
                self?.captureWindow.confirmClearCaptures()
            }
            clear.isEnabled = idle && !store.recordings.isEmpty
            menu.addItem(clear)
        } else {
            menu.addItem(ClosureMenuItem(title: "Show Capture Window") { [weak self] in self?.captureWindow.show() })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Settings…") { [weak self] in self?.showSettings() })
            menu.addItem(ClosureMenuItem(title: "Quit GIF Maker") { NSApp.terminate(nil) })
        }
    }
}

extension NSMenu {
    /// Adds `submenu` under a new top-level item.
    fileprivate func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
