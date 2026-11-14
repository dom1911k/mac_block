import AppKit
import SwiftUI
import Combine
import IntentCore

/// Borderless full-screen window that can take keyboard focus.
final class KioskWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(frame, display: true)
        isOpaque = true
        backgroundColor = .black
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hasShadow = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Small always-on-top timer window shown during a session.
final class SessionPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum UIMode { case none, kiosk, session }

    let model = AppModel()
    private var uiMode: UIMode = .none
    private var kioskWindows: [KioskWindow] = []
    private var panel: SessionPanel?
    private var panelHost: NSHostingView<SessionView>?
    private var timer: Timer?
    private var lastWarning = false
    private var lastState: String?
    private var cancellables = Set<AnyCancellable>()
    var allowQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenLog.write("IntentScreen \(BuildInfo.version) started (pid \(getpid()))")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMainMenu()
        model.poll()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.poll()
            self?.enforceUI(force: true)
        }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.enforceUI(force: true)
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.model.notifyLaunch(pid: app.processIdentifier)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // Deferred: this notification also fires *while* we switch modes (the Dock and menu bar
            // coming back changes the screen layout). Rebuilding the lock windows right then would
            // cover the session timer with a stale lock screen.
            DispatchQueue.main.async {
                guard let self, self.uiMode == .kiosk else { return }
                self.rebuildKioskWindows()
            }
        }
        // React to status changes right away instead of waiting for the next tick.
        model.$status.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.enforceUI() }
        }.store(in: &cancellables)

        enforceUI(force: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        allowQuit ? .terminateNow : .terminateCancel
    }

    private func tick() {
        model.now = Date()
        model.poll()
        enforceUI()
    }

    // MARK: UI switching

    private func enforceUI(force: Bool = false) {
        let st = model.status
        if st?.exempt == true {
            // This account is exempt (e.g. the separate admin account). Exit cleanly; launchd won't restart us.
            allowQuit = true
            NSApp.terminate(nil)
            exit(0)
        }
        let state = (model.daemonReachable ? st?.state : nil) ?? "locked"
        if state != lastState {
            ScreenLog.write("UI: \(lastState ?? "start") → \(state) (daemon reachable: \(model.daemonReachable))")
            model.errorText = nil
            model.confirmEnd = false
            lastState = state
        }
        if state == "locked" {
            showKiosk(force: force)
        } else {
            showSession()
        }
        let warning = st?.warning == true
        if warning && !lastWarning { NSSound(named: "Glass")?.play() }
        lastWarning = warning
    }

    private func showKiosk(force: Bool) {
        if uiMode != .kiosk {
            ScreenLog.write("UI: showing lock screen")
            panel?.orderOut(nil)
            panel = nil
            panelHost = nil
            NSApp.setActivationPolicy(.regular)
            uiMode = .kiosk
            rebuildKioskWindows()
        }
        applyKioskPresentation()
        // While "Join Wi-Fi…" is active, don't grab focus back: the Wi-Fi password dialog needs it.
        let grab = force || !model.wifiActive
        if grab && !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if grab, let main = kioskWindows.first, !main.isKeyWindow || force {
            main.makeKeyAndOrderFront(nil)
        }
        kioskWindows.dropFirst().forEach { $0.orderFrontRegardless() }
    }

    /// Kiosk = no Dock, no menu bar, no ⌘-Tab, no Force Quit window, no logout/restart dialog.
    /// "Join Wi-Fi…" relaxes this for 2 minutes so the menu bar's Wi-Fi menu can be used.
    /// (Only valid combinations are used — invalid ones make AppKit throw.)
    private func applyKioskPresentation() {
        let wifi = model.wifiActive
        let opts: NSApplication.PresentationOptions = wifi
            ? [.autoHideDock, .disableProcessSwitching, .disableForceQuit, .disableSessionTermination, .disableHideApplication]
            : [.hideDock, .hideMenuBar, .disableAppleMenu, .disableProcessSwitching, .disableForceQuit,
               .disableSessionTermination, .disableHideApplication]
        if NSApp.presentationOptions != opts { NSApp.presentationOptions = opts }
        // Normally above everything; during Wi-Fi mode at normal level so menus and password dialogs show on top.
        let level: NSWindow.Level = wifi ? .normal : .screenSaver
        for w in kioskWindows where w.level != level { w.level = level }
    }

    private func rebuildKioskWindows() {
        kioskWindows.forEach { $0.orderOut(nil) }
        kioskWindows.removeAll()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let primary = NSScreen.main ?? screens[0]
        let ordered = [primary] + screens.filter { $0 != primary }
        for (i, screen) in ordered.enumerated() {
            let w = KioskWindow(frame: screen.frame)
            if i == 0 {
                w.contentView = NSHostingView(rootView: LockView(model: model))
            } else {
                let v = NSView(frame: screen.frame)
                v.wantsLayer = true
                v.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).cgColor
                w.contentView = v
            }
            kioskWindows.append(w)
        }
        applyKioskPresentation()
        kioskWindows.first?.makeKeyAndOrderFront(nil)
        kioskWindows.dropFirst().forEach { $0.orderFrontRegardless() }
    }

    private func showSession() {
        if uiMode != .session {
            uiMode = .session   // set first: the calls below trigger screen-change notifications
            ScreenLog.write("UI: showing session timer")
            kioskWindows.forEach { $0.orderOut(nil) }
            kioskWindows.removeAll()
            NSApp.presentationOptions = []
            NSApp.setActivationPolicy(.accessory)
            let p = SessionPanel()
            let host = NSHostingView(rootView: SessionView(model: model))
            p.contentView = host
            panel = p
            panelHost = host
            model.wifiUntil = nil
        }
        // Safety net: no lock windows may exist during a session.
        if !kioskWindows.isEmpty {
            ScreenLog.write("UI: removing \(kioskWindows.count) stray lock window(s) during session")
            kioskWindows.forEach { $0.orderOut(nil) }
            kioskWindows.removeAll()
        }
        guard let p = panel, let host = panelHost else { return }
        // Keep the panel sized to its content and pinned to the top-right corner.
        let size = host.fittingSize
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let frame = NSRect(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 16, width: size.width, height: size.height)
            if p.frame != frame { p.setFrame(frame, display: true) }
        }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    // MARK: menu

    /// Minimal menu: no Quit item (so ⌘Q does nothing) and no Paste.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "Intent Mode")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
