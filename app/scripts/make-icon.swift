// Renders the app icon (warm gradient squircle with an eye symbol) to a 1024px PNG.
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.98, green: 0.62, blue: 0.32, alpha: 1),
                    NSColor(red: 0.80, green: 0.30, blue: 0.16, alpha: 1)])!.draw(in: path, angle: -90)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), .clear])!
    .draw(in: NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0), xRadius: 185, yRadius: 185), angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
