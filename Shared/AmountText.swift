import CoverflexCore
import SwiftUI

/// Amount with the whole part large and bold, and the rest smaller. Shared look with the widget.
struct AmountText: View {
    let amount: FormattedAmount
    let wholeSize: CGFloat
    let restSize: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(amount.whole).font(.system(size: wholeSize, weight: .bold))
            Text(amount.rest).font(.system(size: restSize, weight: .regular))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}
