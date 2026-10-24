import AppKit
import PetCore

@MainActor
final class PetView: NSView {
    let characterLayer = CALayer()
    private var assets: PetAssets
    let videoPlayback = PetVideoPlayback()
    private let message = NSTextField(labelWithString: "")
    private var currentImage: PetAssets.Image?
    private(set) var currentPose: PetPose?
    var skin: PetSkin { assets.skin }
    private var mouseDownPoint: NSPoint?
    private var windowStartOrigin: NSPoint?
    private var dragging = false
    var characterHeight: CGFloat = PetPreferences.Size.medium.characterHeight { didSet { needsLayout = true } }
    var onInteraction: (() -> Void)?
    var onPoke: (() -> Void)?
    var onDrag: ((Bool) -> Void)?
    var onDragEnd: (() -> Void)?

    init(assets: PetAssets) {
        self.assets = assets
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        characterLayer.contentsGravity = .resize
        characterLayer.magnificationFilter = .linear
        characterLayer.minificationFilter = .trilinear
        layer?.addSublayer(characterLayer)
        message.alignment = .center
        message.font = .systemFont(ofSize: 11, weight: .medium)
        message.textColor = .labelColor
        message.backgroundColor = .windowBackgroundColor.withAlphaComponent(0.94)
        message.drawsBackground = true
        message.isBezeled = false
        message.maximumNumberOfLines = 2
        message.cell?.usesSingleLineMode = false
        message.cell?.isScrollable = false
        message.cell?.wraps = true
        message.lineBreakMode = .byWordWrapping
        message.wantsLayer = true
        message.layer?.cornerRadius = 8
        message.layer?.masksToBounds = true
        addSubview(message)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("DSH 桌宠，点击互动，拖动移动")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func useAssets(_ assets: PetAssets) {
        guard self.assets.skin != assets.skin else { return }
        videoPlayback.stop()
        characterLayer.removeAllAnimations()
        self.assets = assets
        currentPose = nil
    }

    func stopVideo() {
        videoPlayback.stop()
        characterLayer.contents = currentImage?.cgImage
    }

    func render(pose: PetPose, text: String, animated: Bool = false) throws {
        if currentPose != pose {
            videoPlayback.stop()
            currentImage = try assets.image(for: pose)
            currentPose = pose
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            characterLayer.contents = currentImage?.cgImage
            CATransaction.commit()
            needsLayout = true
        }
        if animated, let url = assets.videoURL(for: pose) {
            videoPlayback.play(url: url, in: characterLayer)
        } else if videoPlayback.isActive {
            stopVideo()
        }
        if message.stringValue != text {
            message.stringValue = text
            needsLayout = true
        }
        message.isHidden = text.isEmpty
        toolTip = text.isEmpty ? "DSH 桌宠" : text
        setAccessibilityValue(text)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image = currentImage {
            // 按主体参考高度统一人物尺寸，窗口另为整段动画特效包络留白。
            let scale = characterHeight / image.referenceHeight
            let width = CGFloat(image.cgImage.width) * scale
            let height = CGFloat(image.cgImage.height) * scale
            characterLayer.anchorPoint = CGPoint(x: image.anchor.x, y: 1 - image.anchor.y)
            characterLayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            characterLayer.position = CGPoint(x: bounds.midX, y: 8)
            characterLayer.contentsScale = window?.backingScaleFactor ?? 2
            videoPlayback.layout(in: characterLayer.bounds)
        }
        CATransaction.commit()
        let width = bounds.width - 14
        let textHeight = message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0
        let height = min(30, max(18, ceil(textHeight) + 4))
        // 保持原 30 pt 气泡的中心线，避免行数变化时上下跳动。
        message.frame = NSRect(x: 7, y: bounds.height - 19 - height / 2, width: width, height: height)
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        mouseDownPoint = NSEvent.mouseLocation
        windowStartOrigin = window?.frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let origin = windowStartOrigin, let window else { return }
        let point = NSEvent.mouseLocation
        let delta = NSPoint(x: point.x - start.x, y: point.y - start.y)
        if !dragging, hypot(delta.x, delta.y) >= 3 {
            dragging = true
            onDrag?(true)
        }
        if dragging {
            onInteraction?()
            window.setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        onInteraction?()
        if dragging {
            (window as? PetPanel)?.constrainToScreens()
            onDrag?(false)
            onDragEnd?()
        } else { onPoke?() }
        dragging = false
        mouseDownPoint = nil
        windowStartOrigin = nil
    }
}
