import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import CryptoKit

struct Manifest: Decodable {
    struct Bounds: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
    struct Anchor: Decodable { let x: Double; let y: Double }
    struct Pose: Decodable { let file: String; let video: String; let visibleBounds: Bounds; let anchor: Anchor }
    let poses: [String: Pose]
}
func require(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "DSHPetValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func inspect(_ image: CGImage) throws -> String {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    return try pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw NSError(domain: "DSHPetValidation", code: 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var clear = false, visible = false
        for offset in stride(from: 3, to: bytes.count, by: 4) {
            clear = clear || bytes[offset] == 0
            visible = visible || bytes[offset] > 128
        }
        try require(clear && visible, "Decoded frame must contain real transparency and visible content")
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let root = repo.appendingPathComponent("native/Sources/DSHNativePet/Resources/DSHPet")
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
let poses = Set(["idle", "thinking", "working", "waiting", "completed", "error", "sleeping", "poke", "drag"])
try require(Set(manifest.poses.keys) == poses, "DSH Pet must cover all nine states")
try require(FileManager.default.fileExists(atPath: root.appendingPathComponent("LICENSE").path), "Upstream license must ship with the resources")
for name in poses.sorted() {
    let entry = manifest.poses[name]!
    for file in [entry.file, entry.video] {
        try require(file == URL(fileURLWithPath: file).lastPathComponent && !file.contains(".."), "Asset paths must be leaf names")
    }
    guard let source = CGImageSourceCreateWithURL(root.appendingPathComponent(entry.file) as CFURL, nil),
          let poster = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "DSHPetValidation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid poster: \(name)"])
    }
    _ = try inspect(poster)
    let bounds = entry.visibleBounds
    try require(bounds.x >= 0 && bounds.y >= 0 && bounds.width > 0 && bounds.height > 0 && bounds.x + bounds.width <= Double(poster.width) && bounds.y + bounds.height <= Double(poster.height), "Invalid shared bounds: \(name)")
    try require((0...1).contains(entry.anchor.x) && (0...1).contains(entry.anchor.y), "Invalid anchor: \(name)")
    let asset = AVURLAsset(url: root.appendingPathComponent(entry.video))
    let playable = try await asset.load(.isPlayable)
    let duration = try await asset.load(.duration).seconds
    try require(playable && duration.isFinite && duration > 0, "Video is not playable: \(name)")
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let first = try await generator.image(at: CMTime(seconds: 0, preferredTimescale: 600)).image
    let middle = try await generator.image(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)).image
    try require(first.width == poster.width && first.height == poster.height, "Poster/video dimensions differ: \(name)")
    let firstHash = try inspect(first)
    let middleHash = try inspect(middle)
    try require(firstHash != middleHash, "Distinct video samples must contain actual motion: \(name)")
    print("\(name): \(first.width)x\(first.height), duration=\(String(format: "%.2f", duration))s, alpha and motion verified")
}
print("DSH Pet nine original animations validated")
