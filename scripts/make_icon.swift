// Rasterizes the Chirp app icon from its SVG source (Resources/Chirp.svg)
// at exact pixel dimensions — scripts/make_icon.sh then downsamples this
// into the rest of the .iconset sizes. Run directly only for a one-off
// render; scripts/make_icon.sh is the normal entry point.
// Usage: swift scripts/make_icon.swift <input.svg> <output.png>
import AppKit

let args = CommandLine.arguments
guard args.count > 2 else {
    fatalError("Usage: swift make_icon.swift <input.svg> <output.png>")
}
let inputPath = args[1]
let outputPath = args[2]
let pixelSize = 1024

guard let svgImage = NSImage(contentsOfFile: inputPath) else {
    fatalError("Could not load SVG at \(inputPath)")
}

// An explicit pixel-sized NSBitmapImageRep, rather than NSImage.lockFocus(),
// so the output is exactly 1024×1024 regardless of the host display's
// backing scale factor.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize, pixelsHigh: pixelSize,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("Could not create bitmap") }
rep.size = NSSize(width: pixelSize, height: pixelSize)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
svgImage.draw(
    in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
    from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath) at \(pixelSize)x\(pixelSize)")
