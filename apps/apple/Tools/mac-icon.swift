import AppKit

let catalog = URL(fileURLWithPath: "App/Assets.xcassets", isDirectory: true)
let destination = catalog.appendingPathComponent("MacIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
guard
  let master = NSImage(contentsOf: catalog.appendingPathComponent("AppIcon.appiconset/icon.png"))
else { fatalError("Rakazo icon master is missing") }

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = points * scale
    let filename = "icon-\(pixels).png"
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let unit = CGFloat(pixels) / 1024
    let rect = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    NSBezierPath(roundedRect: rect, xRadius: 180 * unit, yRadius: 180 * unit).addClip()
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: destination.appendingPathComponent(filename))
    images.append([
      "idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename,
    ])
  }
}
let metadata: [String: Any] = ["info": ["author": "xcode", "version": 1], "images": images]
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
  .write(to: destination.appendingPathComponent("Contents.json"))
