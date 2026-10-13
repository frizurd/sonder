// Renders Sonder's app icon artwork: a slanted Termina "S" on a dark backdrop.
// Usage: swift scripts/make-icon.swift <output.png> [size] [--layer]
// --layer draws only the letter on transparency (the foreground layer of the .icon bundle).
// Needs the Termina typeface installed (it is not bundled).
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1024) : 1024
let layerOnly = CommandLine.arguments.contains("--layer")

guard let font = NSFont(name: "Termina-Demi", size: size * 0.6) else {
    FileHandle.standardError.write(Data("Termina-Demi is not installed\n".utf8))
    exit(1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext
let bounds = CGRect(x: 0, y: 0, width: size, height: size)

// Full-bleed backdrop (the system applies the icon shape): near-black with a soft lift at the top.
if !layerOnly {
let backdrop = NSGradient(colors: [NSColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1),
                                   NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)])!
backdrop.draw(in: bounds, angle: -90)
let glow = NSGradient(colors: [NSColor(white: 1, alpha: 0.07), NSColor(white: 1, alpha: 0)])!
glow.draw(fromCenter: NSPoint(x: size * 0.5, y: size * 0.78), radius: 0,
          toCenter: NSPoint(x: size * 0.5, y: size * 0.78), radius: size * 0.62, options: [])
}

// The letter, slanted like an oblique (Termina has no italic), centered on its ink.
let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0.95, green: 0.94, blue: 0.91, alpha: 1)]
let glyph = NSAttributedString(string: "S", attributes: attributes)
let line = CTLineCreateWithAttributedString(glyph)
let ink = CTLineGetImageBounds(line, context)
let slant = tan(12 * CGFloat.pi / 180)
context.saveGState()
context.translateBy(x: size / 2, y: size / 2)
context.concatenate(CGAffineTransform(a: 1, b: 0, c: slant, d: 1, tx: 0, ty: 0))
// Soft shadow under the letter for depth.
if !layerOnly { context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                  color: NSColor(white: 0, alpha: 0.45).cgColor) }
context.textPosition = CGPoint(x: -ink.midX, y: -ink.midY)
CTLineDraw(line, context)
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print(output)
