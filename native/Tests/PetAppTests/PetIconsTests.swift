import AppKit
import Testing
@testable import DSHNativePet

@Suite("应用图标")
@MainActor
struct PetIconsTests {
    @Test func bundledMenuBarImageUsesTemplateAtMenuBarSize() throws {
        let image = try #require(PetIcons.menuBarImage())
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.accessibilityDescription == "DSH 桌宠")
        let pdf = try #require(image.representations.compactMap { $0 as? NSPDFImageRep }.first)
        #expect(pdf.bounds == NSRect(x: 0, y: 0, width: 18, height: 18))
    }
}
