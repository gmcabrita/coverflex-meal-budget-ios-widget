import AppIntents
import CoverflexCore
import WidgetKit

// Compiled into both the app and the widget extension. iOS picks the process that runs an intent,
// so each intent type sets its own `RefreshTrigger` for the renew diagnostics.

/// Fetches the meal budget, updates the widget, and returns the balance in euros.
/// For Shortcuts, Siri, and Personal Automations.
struct RefreshMealBudgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Meal Budget"
    static let description = IntentDescription(
        "Fetches the Coverflex meal budget, updates the widget, and returns the balance in euros."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let snapshot = await refreshMealBudget(trigger: .shortcut)
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

/// The refresh button in the widget. Hidden from Shortcuts.
struct RefreshMealBudgetWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Meal Budget from Widget"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        // The widget shows any problem from the snapshot, so this intent does not throw it.
        await refreshMealBudget(trigger: .widgetButton)
        return .result()
    }
}

@discardableResult
private func refreshMealBudget(trigger: RefreshTrigger) async -> BudgetSnapshot {
    let snapshot = await BudgetService.shared.refresh(trigger: trigger)
    WidgetCenter.shared.reloadAllTimelines()
    return snapshot
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
