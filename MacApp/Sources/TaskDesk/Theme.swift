import SwiftUI
import AppKit

enum Appearance: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"
    var scheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}
enum Ink {
    private static func pair(_ light: Int, _ dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let n = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((n >> 16) & 255)/255, green: CGFloat((n >> 8) & 255)/255, blue: CGFloat(n & 255)/255, alpha: 1)
        })
    }
    static let background = pair(0xFBFBFB,0x0A0A0A)
    static let surface = pair(0xFFFFFF,0x0E0E0E)
    static let text = pair(0x2E2E2E,0xF2F2F2)
    static let muted = pair(0x646464,0x999999)
    static let primary = pair(0x8C212C,0xF2F2F2)
    static let onPrimary = pair(0xFFFFFF,0x171717)
    static let secondary = pair(0xF1F1F1,0x1F1F1F)
    static let onSecondary = text
    static let accent = pair(0xECECEC,0x1F1F1F)
    static let onAccent = text
    static let mutedSurface = pair(0xF5F5F5,0x1F1F1F)
    static let border = pair(0xCECECE,0x2E2E2E)
    static let inputBorder = pair(0xC8C8C8,0x2E2E2E)
    static let focusRing = pair(0x8C212C,0xCCCCCC)
    static let control = pair(0x3478D9,0x4D96F1)
    static let success = pair(0x16A34A,0x22C55E)
    static let warning = pair(0xD97706,0xFBBF24)
    static let danger = pair(0xDC2626,0xEF4444)
    static let info = pair(0x2563EB,0x60A5FA)
}
struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.body.weight(.semibold)).padding(.horizontal, 13).padding(.vertical, 7)
            .foregroundStyle(Ink.onPrimary).background(Ink.primary, in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
    }
}
