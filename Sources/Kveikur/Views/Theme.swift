import AppKit
import SwiftUI

/// Nord palette (nordtheme.com) used across the browser, inspector and bars.
enum Theme {
    static let nord0 = NSColor(hex: 0x2E3440)
    static let nord1 = NSColor(hex: 0x3B4252)
    static let nord2 = NSColor(hex: 0x434C5E)
    static let nord3 = NSColor(hex: 0x4C566A)
    static let nord4 = NSColor(hex: 0xD8DEE9)
    static let nord6 = NSColor(hex: 0xECEFF4)
    static let nord7 = NSColor(hex: 0x8FBCBB)
    static let nord8 = NSColor(hex: 0x88C0D0)
    static let nord9 = NSColor(hex: 0x81A1C1)
    static let nord10 = NSColor(hex: 0x5E81AC)
    static let nord13 = NSColor(hex: 0xEBCB8B)
    static let nord14 = NSColor(hex: 0xA3BE8C)
    static let nord15 = NSColor(hex: 0xB48EAD)

    static let background = nord0
    static let inspectorBackground = nord1
    static let barBackground = NSColor(hex: 0x272C36)
    static let separator = nord2
    static let text = nord4
    static let secondaryText = NSColor(hex: 0x7B88A1)
    static let folder = nord8
    static let track = nord7
    static let playlist = nord15
    static let playing = nord14
    static let marked = nord13
    static let selection = nord8
    static let selectionText = nord0
    static let inactiveSelection = nord2
    static let inactiveSelectionText = nord6

    static let accent = Color(nsColor: nord8)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Divider layers are not repositioned when pane frames are set directly, so they stay transparent and each pane
/// draws its own leading edge with `addLeadingEdge`.
final class ThemedSplitView: NSSplitView {
    override var dividerColor: NSColor { .clear }

    static func addLeadingEdge(to pane: NSView) {
        let line = SeparatorLine()
        line.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(line, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: pane.topAnchor),
            line.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
        ])
    }
}

/// Plain view with a fixed fill, for panes and bars.
final class FilledView: NSView {
    var color: NSColor { didSet { needsDisplay = true } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}
