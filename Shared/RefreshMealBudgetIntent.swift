import AppIntents
import CoverflexCore
import WidgetKit

// Compiled into both the app and the widget extension:
// - The widget refresh button runs it inside the widget extension.
// - Shortcuts and automations run it inside the app, in the background.

/// Fetches the meal budget, updates the widget, and returns the balance in euros.
struct RefreshMealBudgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Meal Budget"
    static let description = IntentDescription(
        "Fetches the Coverflex meal budget, updates the widget, and returns the balance in euros."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let snapshot = await BudgetService.shared.refresh()
        WidgetCenter.shared.reloadAllTimelines()

        switch snapshot.problem {
        case let .signInRequired(reason):
            throw RefreshMealBudgetError.signInRequired(reason)
        case let .fetchFailed(message):
            throw RefreshMealBudgetError.fetchFailed(message)
        case nil:
            break
        }

        let cents = snapshot.balanceCents ?? 0
        let text = BudgetFormatting.format(cents: cents).full
        return .result(value: Double(cents) / 100, dialog: "Meal budget: \(text)")
    }
}

enum RefreshMealBudgetError: Error, CustomLocalizedStringResourceConvertible {
    case signInRequired(String)
    case fetchFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case let .signInRequired(reason): "Coverflex session expired. Open Coverflex Budget and sign in again. \(reason)"
        case let .fetchFailed(message): "Could not refresh the meal budget: \(message)"
        }
    }
}
