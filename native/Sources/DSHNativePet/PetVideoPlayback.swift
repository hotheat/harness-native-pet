import AppKit
import AVFoundation
import CoreImage
import CoreVideo

/// 每次播放拥有独立的队列、循环器与图层；切换后旧回调无法修改新角色。
@MainActor
final class PetVideoPlayback {
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var generation = UUID()
    private var itemObservation: NSKeyValueObservation?
    private weak var outputItem: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var readyObservation: NSKeyValueObservation?
    private(set) var videoLayer: AVPlayerLayer?
    private(set) var url: URL?
    private weak var container: CALayer?

    var isActive: Bool { player != nil }
    var currentTime: TimeInterval { player?.currentTime().seconds ?? 0 }
    var hasDecodedFrame: Bool { videoLayer?.isReadyForDisplay == true }

    func play(url: URL, in container: CALayer) {
        guard self.url != url || player == nil else { return }
        stop()
        let generation = self.generation
        self.url = url
        self.container = container
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        let item = AVPlayerItem(url: url)
        let layer = AVPlayerLayer(player: queue)
        layer.backgroundColor = NSColor.clear.cgColor
        layer.videoGravity = .resize
        layer.frame = container.bounds
        container.addSublayer(layer)
        player = queue
        videoLayer = layer
        looper = AVPlayerLooper(player: queue, templateItem: item)
        itemObservation = queue.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.attachVideoOutput()
            }
        }
        readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == generation, self.videoLayer?.isReadyForDisplay == true else { return }
                // 解码首帧就绪后移除底图，避免透明像素下叠着静态人物。
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.container?.contents = nil
                CATransaction.commit()
            }
        }
        queue.play()
    }

    func layout(in bounds: CGRect) {
        videoLayer?.frame = bounds
    }

    /// 从当前队列项的实际解码输出取帧，用于透明截图和验收，绝不返回 PNG 底图。
    func decodedFrame() -> DecodedFrame? {
        guard let player, let output,
              let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let image = CIContext().createCGImage(ciImage, from: ciImage.extent) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var transparent = 0
        var opaque = 0
        if let bytes = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let alpha = bytes[y * stride + x * 4 + 3]
                    if alpha == 0 { transparent += 1 }
                    if alpha == 255 { opaque += 1 }
                }
            }
        }
        return DecodedFrame(image: image, time: player.currentTime().seconds, transparentPixels: transparent, opaquePixels: opaque)
    }

    struct DecodedFrame {
        let image: CGImage
        let time: TimeInterval
        let transparentPixels: Int
        let opaquePixels: Int
    }

    private func attachVideoOutput() {
        if let output, let outputItem { outputItem.remove(output) }
        guard let item = player?.currentItem else { output = nil; outputItem = nil; return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        self.output = output
        outputItem = item
    }

    func stop() {
        generation = UUID()
        itemObservation?.invalidate()
        itemObservation = nil
        if let output, let outputItem { outputItem.remove(output) }
        output = nil
        outputItem = nil
        readyObservation?.invalidate()
        readyObservation = nil
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        videoLayer?.player = nil
        videoLayer?.removeFromSuperlayer()
        videoLayer = nil
        player = nil
        container = nil
        url = nil
    }
}
