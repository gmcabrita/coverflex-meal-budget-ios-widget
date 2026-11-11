import CoverflexCore
import SwiftUI

/// Amount with the whole part large and bold, and the rest smaller. Shared look with the widget.
struct AmountText: View {
    let amount: FormattedAmount
    let wholeFont: Font
    let restFont: Font

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(amount.whole).font(wholeFont)
            Text(amount.rest).font(restFont)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}
