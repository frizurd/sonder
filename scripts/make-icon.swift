// Renders Sonder's app icon artwork: Rodin's The Thinker on a dark backdrop.
// Usage: swift scripts/make-icon.swift <photo.jpg> <output.png> [size] [--layer]
// <photo.jpg> is The Met's public-domain photo of the 1904 plaster cast (object 209021):
//   https://images.metmuseum.org/CRDImages/es/original/4522.jpg
// The statue is lifted from the photo with Vision's subject cutout.
// --layer draws only the statue on transparency (the foreground layer of the .icon bundle).
import AppKit
import CoreImage
import Vision

let args = CommandLine.arguments.filter { $0 != "--layer" }
guard args.count > 2, args[1].lowercased().hasSuffix(".jpg") || args[1].lowercased().hasSuffix(".jpeg") else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <photo.jpg> <output.png> [size] [--layer]\n".utf8))
    exit(1)
}
let photo = URL(fileURLWithPath: args[1])
let output = args[2]
let size = args.count > 3 ? CGFloat(Double(args[3]) ?? 1024) : 1024
let layerOnly = CommandLine.arguments.contains("--layer")

// Lift the statue (figure and rock, not the plinth) off the photo's dark background.
guard let source = CIImage(contentsOf: photo) else { fatalError("can't read \(photo.path)") }
let handler = VNImageRequestHandler(ciImage: source)
let request = VNGenerateForegroundInstanceMaskRequest()
try handler.perform([request])
guard let subject = request.results?.first else { fatalError("no subject found") }
let lifted = CIImage(cvPixelBuffer: try subject.generateMaskedImage(
    ofInstances: subject.allInstances, from: handler, croppedToInstancesExtent: true))

// A touch more contrast and a warm, off-white plaster tone.
let toned = lifted
    .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.12, kCIInputSaturationKey: 0])
    .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 1.0, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 0.985, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0.955, w: 0),
    ])
guard let statue = CIContext().createCGImage(toned, from: toned.extent) else { fatalError("render failed") }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext
context.interpolationQuality = .high
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

// The statue, fit to the icon's safe area and centered on its own extent.
let aspect = CGFloat(statue.width) / CGFloat(statue.height)
let height = size * 0.74
let width = height * aspect
let frame = CGRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height)
if !layerOnly {
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                      color: NSColor(white: 0, alpha: 0.45).cgColor)
}
context.draw(statue, in: frame)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print(output)
