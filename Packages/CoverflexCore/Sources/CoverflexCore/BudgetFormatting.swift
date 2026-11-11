import Foundation

/// A formatted amount split for display: the widget shows `whole` large and bold, `rest` smaller.
/// Example for pt_PT: 12482 cents → whole "124", rest ",82 €".
public struct FormattedAmount: Equatable, Sendable {
    public let whole: String
    public let rest: String

    public var full: String { whole + rest }
}

public enum BudgetFormatting {
    public static func format(cents: Int, locale: Locale = .current) -> FormattedAmount {
        let amount = Decimal(cents) / 100
        let text = amount.formatted(
            .currency(code: "EUR").locale(locale).precision(.fractionLength(2))
        )
        let separator = locale.decimalSeparator ?? "."
        guard let range = text.range(of: separator, options: .backwards) else {
            return FormattedAmount(whole: text, rest: "")
        }
        return FormattedAmount(whole: String(text[..<range.lowerBound]), rest: String(text[range.lowerBound...]))
    }
}
