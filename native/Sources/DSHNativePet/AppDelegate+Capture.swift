import AppKit
import PetCore

extension AppDelegate {
    func capturePreview() {
        guard let capturePath else { return }
        do {
            try writeCapture(to: URL(fileURLWithPath: capturePath))
            NSApp.terminate(nil)
        } catch { fail(error) }
    }

    func captureSkinSwitch() {
        guard let directory = switchCaptureDirectory else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (index, skin) in [PetSkin.character, .dshPet, .character].enumerated() {
                    self.statusMenu?.selectSkin(skin)
                    self.applyPreferences()
                    try await Task.sleep(for: .seconds(max(1.5, self.captureDelay)))
                    guard !self.stopped else { return }
                    try self.writeCapture(to: directory.appendingPathComponent("\(index + 1)-\(skin.rawValue).png"))
                }
                NSApp.terminate(nil)
            } catch { self.fail(error) }
        }
    }

    func writeCapture(to url: URL) throws {
        guard let view = petView, let panel else { throw AppError.invalidArgument("桌宠窗口尚未创建") }
        view.layoutSubtreeIfNeeded()
        let decoded = view.videoPlayback.decodedFrame()
        if view.videoPlayback.isActive, decoded == nil {
            throw AppError.invalidArgument("视频尚无可读取的实际解码帧")
        }
        let savedContents = view.characterLayer.contents
        let videoHidden = view.videoPlayback.videoLayer?.isHidden
        if let decoded {
            view.characterLayer.contents = decoded.image
            view.videoPlayback.videoLayer?.isHidden = true
        }
        defer {
            view.characterLayer.contents = savedContents
            if let videoHidden { view.videoPlayback.videoLayer?.isHidden = videoHidden }
        }
        CATransaction.flush()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw AppError.invalidArgument("无法创建窗口截图")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AppError.invalidArgument("无法编码窗口截图")
        }
        try png.write(to: url)
        let presentation = store.presentation()
        let evidence: [String: Any] = [
            "processID": ProcessInfo.processInfo.processIdentifier,
            "skin": view.skin.rawValue,
            "pose": view.currentPose?.rawValue ?? "",
            "source": decoded == nil ? "poster" : "AVPlayerItemVideoOutput",
            "videoTime": decoded?.time ?? 0,
            "decodedTransparentPixels": decoded?.transparentPixels ?? 0,
            "decodedOpaquePixels": decoded?.opaquePixels ?? 0,
            "playerActive": view.videoPlayback.isActive,
            "playerReady": view.videoPlayback.hasDecodedFrame,
            "characterHeight": view.characterHeight,
            "sizePreference": preferences.size.rawValue,
            "footScreenX": panel.frame.midX,
            "footScreenY": panel.frame.minY + 8,
            "frame": NSStringFromRect(panel.frame),
            "connectedSources": presentation.connectedSources,
            "sessionIDs": presentation.sessions.map(\.sessionId),
            "sourceLabels": status.sourceLabels,
            "storePose": presentation.pose.rawValue,
            "displayText": view.subviews.compactMap { $0 as? NSTextField }.first?.stringValue ?? "",
        ]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: url.deletingPathExtension().appendingPathExtension("json"))
        print("Preview captured from live PetPanel: \(url.path); state=\(demoPose?.rawValue ?? presentation.pose.rawValue); skin=\(view.skin.rawValue); pose=\(view.currentPose?.rawValue ?? ""); source=\(decoded == nil ? "poster" : "AVPlayerItemVideoOutput"); videoTime=\(decoded?.time ?? 0); playerActive=\(view.videoPlayback.isActive)")
        fflush(stdout)
    }
}
