import Foundation

public enum PropertyEntry {
    /// A value as a property field shows it.
    public static func text(of value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale).grouping(.never).precision(.significantDigits(1...12)))
    }

    /// The number to commit from a field that showed `shown`.
    public static func value(of text: String, shown: Double, locale: Locale = .current) -> Double? {
        guard let entered = value(of: text, locale: locale) else { return nil }
        // The field shows twelve digits, and repeating them changes nothing.
        return entered == value(of: Self.text(of: shown, locale: locale), locale: locale) ? shown : entered
    }

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
