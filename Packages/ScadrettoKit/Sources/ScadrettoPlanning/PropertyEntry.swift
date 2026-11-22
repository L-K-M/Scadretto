import Foundation

public enum PropertyEntry {
    /// The number typed into a property field. The locale's decimal separator
    /// is accepted beside `.`; grouping is refused rather than guessed.
    public static func value(of text: String, locale: Locale = .current) -> Double? {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decimal = locale.decimalSeparator, decimal != ".", !input.contains(".") {
            input = input.replacingOccurrences(of: decimal, with: ".")
        }
        guard let value = Double(input), value.isFinite else { return nil }
        return value
    }
}
