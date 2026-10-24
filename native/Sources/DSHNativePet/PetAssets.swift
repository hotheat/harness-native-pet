import AppKit
import ImageIO
import PetCore

struct CharacterManifest: Decodable {
    struct Canvas: Decodable { let width: Double; let height: Double }
    struct Anchor: Decodable { let x: Double; let y: Double }
    struct VisibleBounds: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
    struct Pose: Decodable {
        let file: String
        let video: String?
        let anchor: Anchor
        let visibleBounds: VisibleBounds
    }
    let referenceHeight: Double?
    let canvas: Canvas
    let poses: [String: Pose]
}

@MainActor
final class PetAssets {
    struct Image {
        let cgImage: CGImage
        let anchor: CGPoint
        let visibleBounds: CGRect
        let referenceHeight: CGFloat
    }
    let skin: PetSkin
    let manifest: CharacterManifest
    private let directory: URL
    var resourceRoot: URL { directory }
    private var cache: [PetPose: Image] = [:]

    init(skin: PetSkin = .character, directory: URL? = nil) throws {
        self.skin = skin
        let packaged = Bundle.main.resourceURL?.appendingPathComponent(skin.resourceDirectory)
        let packagedExists = packaged.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let isApp = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        let root = directory ?? ((isApp || packagedExists) ? packaged! : Bundle.module.resourceURL!.appendingPathComponent(skin.resourceDirectory))
        self.directory = root
        manifest = try JSONDecoder().decode(CharacterManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.canvas.width > 0, manifest.canvas.height > 0,
              manifest.referenceHeight.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw AssetError.invalid("画布尺寸无效")
        }
        for pose in PetPose.allCases {
            guard let entry = manifest.poses[pose.rawValue],
                  (0...1).contains(entry.anchor.x), (0...1).contains(entry.anchor.y),
                  Self.isFileName(entry.file),
                  entry.video.map(Self.isFileName) ?? true,
                  entry.visibleBounds.width > 0, entry.visibleBounds.height > 0,
                  entry.visibleBounds.x >= 0, entry.visibleBounds.y >= 0 else {
                throw AssetError.invalid("姿态资源无效：\(pose.rawValue)")
            }
        }
    }

    func image(for pose: PetPose) throws -> Image {
        if let image = cache[pose] { return image }
        let entry = manifest.poses[pose.rawValue]!
        let url = directory.appendingPathComponent(entry.file)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AssetError.invalid("无法读取角色资源：\(entry.file)")
        }
        guard [.first, .last, .premultipliedFirst, .premultipliedLast].contains(cgImage.alphaInfo) else {
            throw AssetError.invalid("角色资源缺少透明通道：\(entry.file)")
        }
        let bounds = CGRect(x: entry.visibleBounds.x, y: entry.visibleBounds.y,
                            width: entry.visibleBounds.width, height: entry.visibleBounds.height)
        guard bounds.maxX <= CGFloat(cgImage.width), bounds.maxY <= CGFloat(cgImage.height) else {
            throw AssetError.invalid("可见边界超出图像：\(entry.file)")
        }
        let image = Image(cgImage: cgImage, anchor: CGPoint(x: entry.anchor.x, y: entry.anchor.y), visibleBounds: bounds,
                          referenceHeight: manifest.referenceHeight.map { CGFloat($0) } ?? bounds.height)
        cache[pose] = image
        return image
    }

    func requiredPanelSize(characterHeight: CGFloat) throws -> NSSize {
        var size = NSSize(width: max(140, characterHeight + 14), height: characterHeight + 54)
        for pose in PetPose.allCases {
            let image = try image(for: pose)
            let scale = characterHeight / image.referenceHeight
            let anchor = CGPoint(x: image.anchor.x * CGFloat(image.cgImage.width),
                                 y: image.anchor.y * CGFloat(image.cgImage.height))
            let halfWidth = max(anchor.x - image.visibleBounds.minX, image.visibleBounds.maxX - anchor.x) * scale
            let aboveFoot = (anchor.y - image.visibleBounds.minY) * scale
            size.width = max(size.width, ceil(halfWidth * 2 + 14))
            size.height = max(size.height, ceil(8 + aboveFoot + 44))
        }
        return size
    }

    func videoURL(for pose: PetPose) -> URL? {
        manifest.poses[pose.rawValue]?.video.map { directory.appendingPathComponent($0) }
    }

    func validateAll() throws {
        for pose in PetPose.allCases {
            _ = try image(for: pose)
            if let video = videoURL(for: pose), !FileManager.default.fileExists(atPath: video.path) {
                throw AssetError.invalid("无法读取角色视频：\(video.lastPathComponent)")
            }
        }
    }

    private static func isFileName(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("..")
    }

    enum AssetError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case let .invalid(message): message } }
    }
}
