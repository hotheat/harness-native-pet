import Foundation
import ImageIO
import CoreGraphics

struct Manifest: Decodable {
    struct Canvas: Decodable { let width: Double; let height: Double }
    struct Anchor: Decodable { let x: Double; let y: Double }
    struct Bounds: Decodable { let x: Int; let y: Int; let width: Int; let height: Int }
    struct Pose: Decodable { let file: String; let anchor: Anchor; let width: Int; let height: Int; let visibleBounds: Bounds }
    let canvas: Canvas
    let poses: [String: Pose]
}
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let root = repo.appendingPathComponent("native/Sources/DSHNativePet/Resources/Character")
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
let expected = Set(["idle", "thinking", "working", "waiting", "completed", "error", "sleeping", "poke", "drag"])
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "AssetValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
try require(Set(manifest.poses.keys) == expected, "Manifest must map all nine poses")
try require(manifest.canvas.width > 0 && manifest.canvas.height > 0, "Canvas dimensions must be positive")
for name in expected.sorted() {
    let pose = manifest.poses[name]!
    try require((0...1).contains(pose.anchor.x) && (0...1).contains(pose.anchor.y), "Invalid anchor: \(name)")
    try require(pose.file == URL(fileURLWithPath: pose.file).lastPathComponent, "Asset paths must be leaf names")
    let url = root.appendingPathComponent(pose.file)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "AssetValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot load \(url.path)"])
    }
    let w = image.width, h = image.height
    try require(w > 0 && h > 0 && w <= 4096 && h <= 4096, "Unexpected asset dimensions: \(name)")
    try require(pose.width == w && pose.height == h, "Manifest image dimensions do not match: \(name)")
    let bounds = pose.visibleBounds
    try require(bounds.x >= 0 && bounds.y >= 0 && bounds.width > 0 && bounds.height > 0 && bounds.x + bounds.width <= w && bounds.y + bounds.height <= h, "Invalid visible bounds: \(name)")
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let transparent = pixels.withUnsafeMutableBytes { bytes -> (Bool, Bool) in
        let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var clear = false, visible = false
        for offset in stride(from: 3, to: bytes.count, by: 4) {
            let alpha = bytes[offset]
            clear = clear || alpha == 0
            visible = visible || alpha > 128
            if clear && visible { break }
        }
        return (clear, visible)
    }
    try require(transparent.0 && transparent.1, "Asset must contain genuine transparency and a visible character: \(name)")
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 200 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    try require(bounds.x == minX && bounds.y == minY && bounds.width == maxX - minX + 1 && bounds.height == maxY - minY + 1, "Visible bounds do not match alpha pixels: \(name)")
    print("\(name): \(w)x\(h), transparent, anchor=(\(pose.anchor.x),\(pose.anchor.y))")
}
print("Character assets validated")
