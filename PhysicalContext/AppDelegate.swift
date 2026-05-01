import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem:  NSStatusItem?
    private var menuBarMenu: NSMenu?

    private var sessionPanel:    NSWindow?
    private var panelVFX:        NSVisualEffectView?
    private var panelHosting:    NSHostingView<SessionPanelView>?

    private var allSessionsWindow:  NSWindow?
    private var allSessionsVFX:     NSVisualEffectView?
    private var allSessionsHosting: NSHostingView<AllSessionsView>?

    private var settingsWindow:  NSWindow?
    private var settingsVFX:     NSVisualEffectView?
    private var settingsHosting: NSHostingView<SettingsView>?

    private var summaryControllers: [SummaryWindowBox] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        AppMonitor.shared.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppMonitor.shared.stopMonitoring()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let btn = statusItem?.button else { return }
        btn.image = NSImage(systemSymbolName: "hexagon.fill",
                            accessibilityDescription: "Physical Context")
        btn.image?.isTemplate = true
        btn.action = #selector(statusItemClicked)
        btn.target  = self
        btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        rebuildMenu()
        statusItem?.menu = menuBarMenu
        statusItem?.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in self?.statusItem?.menu = nil }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if let s = SessionManager.shared.currentSession {
            addDisabled("● \(s.appName) — active", to: menu)
            addItem("Toggle Panel",  #selector(togglePanel),    to: menu)
            addItem("End Session",   #selector(endSessionMenu), to: menu)
            menu.addItem(.separator())
        } else {
            addDisabled("No active session", to: menu)
            menu.addItem(.separator())
        }
        addItem("All Sessions", #selector(showAllSessions), to: menu)
        addItem("Settings…",    #selector(showSettings),    to: menu, key: ",")
        menu.addItem(.separator())
        addItem("Quit Physical Context",
                #selector(NSApplication.terminate(_:)), to: menu, key: "q")
        menuBarMenu = menu
    }

    private func addItem(_ title: String, _ action: Selector,
                         to menu: NSMenu, key: String = "") {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self; menu.addItem(i)
    }
    private func addDisabled(_ title: String, to menu: NSMenu) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false; menu.addItem(i)
    }

    // MARK: - Session Panel

    func showSessionPanel() {
        if sessionPanel == nil { buildSessionPanel() }
        NSApp.setActivationPolicy(.accessory)
        sessionPanel?.orderFrontRegardless()
    }

    func hideSessionPanel() { sessionPanel?.orderOut(nil) }

    @objc private func togglePanel() {
        guard let p = sessionPanel else { showSessionPanel(); return }
        p.isVisible ? p.orderOut(nil) : p.orderFrontRegardless()
    }
    @objc private func endSessionMenu() { SessionManager.shared.endSession() }

    private let panelHeight:       CGFloat = 520
    private let panelCollapsedW:   CGFloat = 52
    private let panelExpandedW:    CGFloat = 300

    private func buildSessionPanel() {
        // Start collapsed
        let w = panelCollapsedW
        let h = panelHeight

        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask:   [.borderless, .fullSizeContentView,
                          .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        win.isFloatingPanel             = true
        win.level                       = .floating
        win.isMovableByWindowBackground = true
        win.isOpaque                    = false
        win.backgroundColor             = .clear
        win.hasShadow                   = true
        win.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed        = false

        // Anchor to right edge of screen
        if let screen = NSScreen.main {
            let sv = screen.visibleFrame
            win.setFrameOrigin(NSPoint(x: sv.maxX - w - 8,
                                       y: sv.midY - h / 2))
        }

        // ✅ VFX as contentView — NSHostingView as subview
        let bounds = NSRect(x: 0, y: 0, width: w, height: h)
        let vfx = NSVisualEffectView(frame: bounds)
        vfx.autoresizingMask = [.width, .height]
        vfx.material         = .hudWindow        // darker than underWindowBackground
        vfx.blendingMode     = .behindWindow
        vfx.state            = .active
        vfx.appearance       = NSAppearance(named: .darkAqua)
        vfx.wantsLayer       = true
        vfx.layer?.cornerRadius  = 16
        vfx.layer?.masksToBounds = true

        // Pass resize callback so SwiftUI can drive window width
        let hosting = NSHostingView(rootView: SessionPanelView { [weak self, weak win] newWidth in
            guard let self, let win else { return }
            var frame = win.frame
            let oldRight = frame.maxX
            frame.size.width = newWidth
            frame.origin.x   = oldRight - newWidth
            win.setFrame(frame, display: true, animate: true)
            // Re-anchor the VFX after resize
            self.panelVFX?.frame = NSRect(x: 0, y: 0, width: newWidth, height: self.panelHeight)
        })
        hosting.frame            = bounds
        hosting.autoresizingMask = [.width, .height]
        vfx.addSubview(hosting)
        win.contentView = vfx

        sessionPanel  = win
        panelVFX      = vfx
        panelHosting  = hosting
    }

    // MARK: - Session Summary

    func showSessionSummary(session: Session) {
        let (win, vfx) = makeWindow(width: 660, height: 640, title: "Session Summary")
        win.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SessionSummaryView(session: session))
        hosting.frame = vfx.bounds; hosting.autoresizingMask = [.width, .height]
        vfx.addSubview(hosting); win.contentView = vfx
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        summaryControllers.append(SummaryWindowBox(window: win, vfx: vfx, hosting: hosting))
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.summaryControllers.removeAll { !$0.window.isVisible }
        }
    }

    // MARK: - All Sessions

    @objc func showAllSessions() {
        if let w = allSessionsWindow, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let (win, vfx) = makeWindow(width: 720, height: 560, title: "All Sessions")
        win.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AllSessionsView())
        hosting.frame = vfx.bounds; hosting.autoresizingMask = [.width, .height]
        vfx.addSubview(hosting); win.contentView = vfx
        allSessionsWindow = win; allSessionsVFX = vfx; allSessionsHosting = hosting
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: - Settings

    @objc func showSettings() {
        if let w = settingsWindow, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let (win, vfx) = makeWindow(width: 440, height: 380, title: "Settings")
        win.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: SettingsView())
        hosting.frame = vfx.bounds; hosting.autoresizingMask = [.width, .height]
        vfx.addSubview(hosting); win.contentView = vfx
        settingsWindow = win; settingsVFX = vfx; settingsHosting = hosting
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: - Helpers

    private func makeWindow(width: CGFloat, height: CGFloat,
                            title: String) -> (NSWindow, NSVisualEffectView) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask:   [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title                      = title
        win.titlebarAppearsTransparent = true
        win.isOpaque                   = false
        win.backgroundColor            = .clear
        win.hasShadow                  = true
        win.appearance                 = NSAppearance(named: .darkAqua)
        win.center()
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let vfx    = NSVisualEffectView(frame: bounds)
        vfx.autoresizingMask = [.width, .height]
        vfx.material         = .underWindowBackground
        vfx.blendingMode     = .behindWindow
        vfx.state            = .active
        vfx.appearance       = NSAppearance(named: .darkAqua)
        vfx.wantsLayer       = true
        return (win, vfx)
    }
}

private struct SummaryWindowBox {
    let window:  NSWindow
    let vfx:     NSVisualEffectView
    let hosting: NSHostingView<SessionSummaryView>
}
