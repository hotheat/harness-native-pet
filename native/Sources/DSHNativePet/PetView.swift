import AppKit
import PetCore
import SwiftUI

private struct PetBubbleView: View {
    let text: String
    var width: CGFloat?

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
            .frame(width: width)
    }
}

private final class PetBubbleHostingView: NSHostingView<PetBubbleView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class PetView: NSView {
    let characterLayer = CALayer()
    private var assets: PetAssets
    let videoPlayback = PetVideoPlayback()
    private let message = PetBubbleHostingView(rootView: PetBubbleView(text: ""))
    private(set) var displayText = ""
    var bubbleFrame: NSRect { message.frame }
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
        message.isHidden = true
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
        if displayText != text {
            displayText = text
            message.rootView = PetBubbleView(text: text, width: message.rootView.width)
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
        // fittingSize 按 SwiftUI 的宽度提案换行，再由文字和内边距决定高度。
        if message.rootView.width != width {
            message.rootView.width = width
        }
        let height = min(32, message.fittingSize.height)
        // 保持历史气泡中心线，避免行数变化时上下跳动。
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
