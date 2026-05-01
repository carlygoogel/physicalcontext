import SwiftUI
import AppKit


struct SessionPromptView: View {
    let app:       CADApp
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            // ✅ Solid near-black — covers everything, no grey bleed
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.08, green: 0.09, blue: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 18, y: 6)
                .ignoresSafeArea()

            HStack(spacing: 12) {
                // App icon badge
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(hex: "#5B8DEF").opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: app.sfSymbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Color(hex: "#5B8DEF"))
                }

                // Title + subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Detected — start a session?")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.40))
                }

                Spacer()

                // Buttons
                HStack(spacing: 8) {
                    Button("Later") {
                        DispatchQueue.main.async { onDismiss() }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.45))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.white.opacity(0.07))
                    .cornerRadius(7)
                    .buttonStyle(.plain)

                    Button {
                        DispatchQueue.main.async { onConfirm() }
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
// MARK: - Button Styles

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(12, .medium))
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.surfaceHigh : Theme.surface)
            .cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 0.5))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.accentBright.opacity(0.8) : Theme.accentBright)
            .cornerRadius(7)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(12, .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.danger.opacity(0.75) : Theme.danger.opacity(0.85))
            .cornerRadius(7)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
