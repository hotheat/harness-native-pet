import AppKit

@MainActor
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        setAccessibilityLabel("DSH 桌宠")
    }

    static func constrain(_ frame: NSRect, to area: NSRect) -> NSRect {
        var result = frame
        result.origin.x = min(max(frame.minX, area.minX), max(area.minX, area.maxX - frame.width))
        result.origin.y = min(max(frame.minY, area.minY), max(area.minY, area.maxY - frame.height))
        return result
    }

    func constrainToScreens() {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { intersectionArea($0.visibleFrame) < intersectionArea($1.visibleFrame) }
        if let screen { setFrame(Self.constrain(frame, to: screen.visibleFrame), display: true) }
    }

    private func intersectionArea(_ other: NSRect) -> CGFloat {
        let intersection = frame.intersection(other)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
