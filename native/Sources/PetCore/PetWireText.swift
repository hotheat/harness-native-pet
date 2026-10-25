import Foundation

/// Shared title/label semantics at producer and decoder boundaries.
public enum PetWireText {
    public static let maximumScalars = 256

    public static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = String(clean.unicodeScalars.prefix(maximumScalars))
        return result.isEmpty ? nil : result
    }
}
