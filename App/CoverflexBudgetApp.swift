import AppIntents
import CoverflexCore
import SwiftUI
import UIKit
import WidgetKit

@main
struct CoverflexBudgetApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { url in
                    switch AppLink(url: url) {
                    case .openCoverflex: openCoverflexApp()
                    case .signIn: model.isSignInPresented = true
                    case nil: break
                    }
                }
        }
    }

    /// Widgets can only open their own app, so the widget opens this app, which forwards to Coverflex.
    /// The Coverflex app handles `my.coverflex.com` universal links. Safari opens it when the app is missing.
    private func openCoverflexApp() {
        let url = AppLink.coverflexWebURL
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
            if !opened { UIApplication.shared.open(url) }
        }
    }
}

/// Registers the refresh intent with Shortcuts and Siri. The intent is also available
/// in the Shortcuts action list and in Personal Automations.
struct CoverflexBudgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshMealBudgetIntent(),
            phrases: [
                "Refresh meal budget in \(.applicationName)",
                "Update \(.applicationName)",
            ],
            shortTitle: "Refresh Meal Budget",
            systemImageName: "arrow.clockwise"
        )
    }
}

@MainActor
@Observable
final class AppModel {
    var snapshot = BudgetSnapshot()
    var hasTokens = false
    var isRefreshing = false
    /// Set by the widget sign-in link. Shows the form even when tokens are present.
    var isSignInPresented = false

    var showsSignIn: Bool { !hasTokens || snapshot.needsSignIn || isSignInPresented }

    func load() async {
        snapshot = await BudgetService.shared.snapshot
        hasTokens = await BudgetService.shared.hasTokens
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        snapshot = await BudgetService.shared.refresh()
        hasTokens = await BudgetService.shared.hasTokens
        WidgetCenter.shared.reloadAllTimelines()
    }

    func completeSignIn(with tokens: AuthTokens) async throws {
        snapshot = try await BudgetService.shared.completeSignIn(with: tokens)
        hasTokens = await BudgetService.shared.hasTokens
        isSignInPresented = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    func signOut() async {
        await BudgetService.shared.signOut()
        await load()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
