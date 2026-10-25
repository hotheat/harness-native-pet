import AppKit

/// Fits a title while retaining the complete status, using the bubble's actual text area.
enum PetBubbleFit {
    static func text(title: String, status: String, bubbleWidth: CGFloat, statusOnNewLine: Bool = false) -> String {
        let characters = Array(title)
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textWidth = bubbleWidth - 14 // SwiftUI's horizontal padding: 7pt per side.
        for count in stride(from: characters.count, through: 1, by: -1) {
            let shortened = String(characters.prefix(count)) + (count < characters.count ? "…" : "")
            let candidate = "「\(shortened)」" + (statusOnNewLine ? "\n" : "") + status
            let storage = NSTextStorage(string: candidate, attributes: [.font: font])
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
            if lines <= 2 && layout.usedRect(for: container).height + 4 <= 32 { return candidate }
        }
        return status
    }
}
