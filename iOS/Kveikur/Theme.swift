import SwiftUI

enum Nord {
    static let n0 = Color(hex: 0x2E3440)
    static let n1 = Color(hex: 0x3B4252)
    static let n2 = Color(hex: 0x434C5E)
    static let n3 = Color(hex: 0x4C566A)
    static let n4 = Color(hex: 0xD8DEE9)
    static let n6 = Color(hex: 0xECEFF4)
    static let n7 = Color(hex: 0x8FBCBB)
    static let n8 = Color(hex: 0x88C0D0)
    static let n10 = Color(hex: 0x5E81AC)
    static let n13 = Color(hex: 0xEBCB8B)
    static let n14 = Color(hex: 0xA3BE8C)
    static let n15 = Color(hex: 0xB48EAD)

    static let background = n0
    static let raised = n1
    static let bar = Color(hex: 0x272C36)
    static let text = n4
    static let secondary = Color(hex: 0x7B88A1)
    static let folder = n8
    static let playing = n14
    static let accent = n8
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Format {
    static func duration(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// Nord list styling shared by every screen.
struct NordList: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Nord.background)
            .listRowBackground(Nord.background)
    }
}

extension View {
    func nordList() -> some View { modifier(NordList()) }
}
