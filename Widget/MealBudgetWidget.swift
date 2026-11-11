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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                Text("Coverflex")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "fork.knife")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.background)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.primary))
            }

            amount
            status

            Spacer(minLength: 0)

            HStack(alignment: .bottom) {
                Button(intent: RefreshMealBudgetIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.fill.tertiary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh meal budget")

                Spacer(minLength: 4)

                if let fetchedAt = snapshot.fetchedAt {
                    Text(Self.updatedLabel(fetchedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(AppLink.widgetTap(for: snapshot).url)
    }

    @ViewBuilder private var amount: some View {
        if let cents = snapshot.balanceCents {
            AmountText(amount: BudgetFormatting.format(cents: cents), wholeSize: 30, restSize: 20)
                .foregroundStyle(snapshot.needsSignIn ? .secondary : .primary)
                .invalidatableContent()
        } else {
            Text("—").font(.system(size: 30, weight: .bold))
        }
    }

    @ViewBuilder private var status: some View {
        switch snapshot.problem {
        case .signInRequired:
            Label("Tap to sign in", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        case .fetchFailed:
            Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
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
    MealBudgetEntry(date: .now, snapshot: BudgetSnapshot(balanceCents: 325, fetchedAt: .now, problem: .signInRequired))
    MealBudgetEntry(date: .now, snapshot: BudgetSnapshot(problem: .signInRequired))
}
