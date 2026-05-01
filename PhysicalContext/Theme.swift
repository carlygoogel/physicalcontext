import SwiftUI

// MARK: - Design Tokens

enum Theme {
    static let background   = Color(hex: "#09090B")
    static let surface      = Color(hex: "#111113")
    static let surfaceHigh  = Color(hex: "#18181B")
    static let border       = Color(hex: "#27272A")
    static let borderFaint  = Color(hex: "#1C1C1F")
    static let accent       = Color(hex: "#818CF8")   // indigo-400
    static let accentBright = Color(hex: "#6366F1")   // indigo-500
    static let accentDim    = Color(hex: "#818CF8").opacity(0.12)
    static let textPrimary  = Color(hex: "#F4F4F5")
    static let textSecondary = Color(hex: "#71717A")
    static let textTertiary  = Color(hex: "#3F3F46")
    static let success      = Color(hex: "#34D399")
    static let warning      = Color(hex: "#FBBF24")
    static let danger       = Color(hex: "#F87171")

    // Typography
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 200, 200, 200)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Reusable View Modifiers

struct SurfaceCard: ViewModifier {
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
    }
}

struct HighCard: ViewModifier {
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surfaceHigh)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
    }
}

extension View {
    func surfaceCard(_ padding: CGFloat = 12) -> some View { modifier(SurfaceCard(padding: padding)) }
    func highCard(_ padding: CGFloat = 12) -> some View { modifier(HighCard(padding: padding)) }
}

// MARK: - Tag View

struct TagView: View {
    let label: String
    var color: Color = Theme.accent

    var body: some View {
        Text(label)
            .font(Theme.mono(9, .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(4)
    }
}

// MARK: - Dot indicator

struct PulseDot: View {
    @State private var pulsing = false
    var color: Color = Theme.success

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 12, height: 12)
                .scaleEffect(pulsing ? 1.5 : 1)
                .opacity(pulsing ? 0 : 1)
                .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulsing)

            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .onAppear { pulsing = true }
    }
}
