import AppIntents
import CoverflexCore
import SwiftUI
import WidgetKit

@main
struct CoverflexBudgetWidgetBundle: WidgetBundle {
    var body: some Widget {
        MealBudgetWidget()
    }
}

struct MealBudgetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MealBudgetWidget", provider: MealBudgetProvider()) { entry in
            MealBudgetWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Meal Budget")
        .description("Coverflex meal card balance.")
        .supportedFamilies([.systemSmall])
        // The view sets its own padding to match the Revolut widget layout.
        .contentMarginsDisabled()
    }
}

struct MealBudgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BudgetSnapshot
}

struct MealBudgetProvider: TimelineProvider {
    /// The widget fetches on its own at most this often. The refresh button and Shortcuts fetch on demand.
    private static let reloadInterval: TimeInterval = 30 * 60
    /// After the refresh button runs, WidgetKit reloads the timeline. A snapshot this recent is reused.
    private static let reuseInterval: TimeInterval = 2 * 60

    private static let sample = BudgetSnapshot(balanceCents: 325, fetchedAt: .now)

    func placeholder(in context: Context) -> MealBudgetEntry {
        MealBudgetEntry(date: .now, snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (MealBudgetEntry) -> Void) {
        if context.isPreview {
            completion(MealBudgetEntry(date: .now, snapshot: Self.sample))
            return
        }
        Task { completion(MealBudgetEntry(date: .now, snapshot: await BudgetService.shared.snapshot)) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<MealBudgetEntry>) -> Void) {
        Task {
            let snapshot = await BudgetService.shared.refreshIfOlder(than: Self.reuseInterval)
            let entry = MealBudgetEntry(date: .now, snapshot: snapshot)
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(Self.reloadInterval))))
        }
    }
}

struct MealBudgetWidgetView: View {
    let snapshot: BudgetSnapshot

    // Sizes measured from the Revolut small widget on an iPhone screenshot.
    // Fixed font sizes: Dynamic Type would push the amount or the buttons out of the widget.
    private enum Layout {
        static let padding: CGFloat = 16
        static let headerFontSize: CGFloat = 15
        static let badgeSize: CGFloat = 20
        static let wholeFontSize: CGFloat = 25
        static let restFontSize: CGFloat = 17
        static let buttonSize: CGFloat = 48
        static let buttonIconSize: CGFloat = 19
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Coverflex")
                    .font(.system(size: Layout.headerFontSize, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.56))
                Spacer(minLength: 4)
                Image(systemName: "fork.knife")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.background)
                    .frame(width: Layout.badgeSize, height: Layout.badgeSize)
                    .background(Circle().fill(.primary))
            }

            amount
            status
                .padding(.top, 2)

            Spacer(minLength: 0)

            HStack(alignment: .center) {
                Button(intent: RefreshMealBudgetIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: Layout.buttonIconSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: Layout.buttonSize, height: Layout.buttonSize)
                        .background(Circle().fill(.fill.tertiary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh meal budget")

                Spacer(minLength: 4)

                if let fetchedAt = snapshot.fetchedAt {
                    Text(Self.updatedLabel(fetchedAt))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.4))
                }
            }
        }
        .padding(Layout.padding)
        .containerBackground(.background, for: .widget)
        .widgetURL(AppLink.widgetTap(for: snapshot).url)
    }

    @ViewBuilder private var amount: some View {
        if let cents = snapshot.balanceCents {
            AmountText(
                amount: BudgetFormatting.format(cents: cents),
                wholeSize: Layout.wholeFontSize,
                restSize: Layout.restFontSize
            )
            .foregroundStyle(snapshot.needsSignIn ? .secondary : .primary)
            .invalidatableContent()
        } else {
            Text("—").font(.system(size: Layout.wholeFontSize, weight: .bold))
        }
    }

    @ViewBuilder private var status: some View {
        switch snapshot.problem {
        case .signInRequired:
            Label("Tap to sign in", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
        case .fetchFailed:
            Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    /// Time for today, day and month for older values.
    private static func updatedLabel(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated))
    }
}

#Preview(as: .systemSmall) {
    MealBudgetWidget()
} timeline: {
    MealBudgetEntry(date: .now, snapshot: BudgetSnapshot(balanceCents: 12482, fetchedAt: .now))
    MealBudgetEntry(date: .now, snapshot: BudgetSnapshot(balanceCents: 325, fetchedAt: .now, problem: .fetchFailed("Offline")))
    MealBudgetEntry(date: .now, snapshot: BudgetSnapshot(balanceCents: 325, fetchedAt: .now, problem: .signInRequired("")))
    MealBudgetEntry(date: .now, snapshot: BudgetSnapshot(problem: .signInRequired("")))
}
