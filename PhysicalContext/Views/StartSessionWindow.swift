// UI/StartSessionWindow.swift — Physical Context

import AppKit
import SwiftUI

// Use a single shared controller instance so we always have a strong reference
// and can close it reliably.
final class StartSessionWindowController {

    static let shared = StartSessionWindowController()
    private init() {}

    private var window:  NSWindow?
    private var hosting: NSHostingView<PromptPillView>?

    func show(app: CADApp, completion: @escaping (Bool) -> Void) {
        // Dismiss any existing prompt first
        dismiss()

        let w: CGFloat = 380, h: CGFloat = 72

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask:   [.borderless, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed        = false   // we manage lifetime
        win.level                       = .floating
        win.isOpaque                    = false
        win.backgroundColor             = .clear
        win.hasShadow                   = true
        win.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let sv = screen.visibleFrame
            win.setFrameOrigin(NSPoint(x: sv.maxX - w - 16, y: sv.maxY - h - 8))
        }

        let hv = NSHostingView(
            rootView: PromptPillView(
                app: app,
                onConfirm: { [weak self] in
                    // ✅ Dismiss FIRST, then call completion — avoids window
                    // still being on screen when session panel tries to appear
                    self?.dismiss()
                    completion(true)
                },
                onDismiss: { [weak self] in
                    self?.dismiss()
                    completion(false)
                }
            )
        )
        hv.frame            = NSRect(x: 0, y: 0, width: w, height: h)
        hv.autoresizingMask = [.width, .height]
        win.contentView     = hv

        // Store strong refs so ARC doesn't free them when this func returns
        self.window  = win
        self.hosting = hv

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        // Auto-dismiss after 14 s
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
            guard self?.window != nil else { return }
            self?.dismiss()
            completion(false)
        }
    }

    func dismiss() {
        window?.orderOut(nil)
        window?.close()
        // Nil out after a tick so any in-flight SwiftUI update finishes
        let keepWin     = window
        let keepHosting = hosting
        window  = nil
        hosting = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            _ = keepWin; _ = keepHosting
        }
    }
}

// ─── Prompt pill view ─────────────────────────────────────────────────────────

struct PromptPillView: View {
    let app:       CADApp
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 18, y: 6)
                .ignoresSafeArea()

            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(hex: "#5B8DEF").opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: app.sfSymbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Color(hex: "#5B8DEF"))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Detected — start a session?")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.40))
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Later") { onDismiss() }
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.45))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.white.opacity(0.07))
                        .cornerRadius(7)
                        .buttonStyle(.plain)

                    Button {
                        onConfirm()
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hex: "#4CC38A"))
                                .frame(width: 6, height: 6)
                            Text("Start")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color(hex: "#5B8DEF").opacity(0.85))
                        .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(width: 380, height: 72)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -8)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }
}

// ─── Shared button styles ─────────────────────────────────────────────────────

struct PCPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(hex: "#5B8DEF").opacity(configuration.isPressed ? 0.70 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PCSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 18).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(configuration.isPressed ? 0.04 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}
