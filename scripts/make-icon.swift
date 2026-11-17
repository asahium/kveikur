// Renders the app icon: a flat, single-colour Prussian blue squircle.
// Usage: swift scripts/make-icon.swift <output.png> [--full]
// --full fills the whole opaque square for iOS, which applies its own mask.
import AppKit

let args = CommandLine.arguments.dropFirst()
let out = args.first { !$0.hasPrefix("--") } ?? "icon.png"
let full = args.contains("--full")
let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: (full ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let prussian: UInt32 = 0x003153
if full {
    ctx.addRect(CGRect(x: 0, y: 0, width: size, height: size))
} else {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
}
ctx.setFillColor(rgb(prussian))
ctx.fillPath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
