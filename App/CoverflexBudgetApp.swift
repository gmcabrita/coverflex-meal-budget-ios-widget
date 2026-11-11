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
    var hasSession = false
    var accessTokenExpiry: Date?
    var refreshTokenExpiry: Date?
    var isRefreshing = false
    /// Set by the widget sign-in link. Shows the form even when a session is present.
    var isSignInPresented = false

    var showsSignIn: Bool { !hasSession || snapshot.needsSignIn || isSignInPresented }

    func load() async {
        snapshot = await BudgetService.shared.snapshot
        await loadTokenState()
    }

    private func loadTokenState() async {
        hasSession = await BudgetService.shared.hasSession
        (accessTokenExpiry, refreshTokenExpiry) = await BudgetService.shared.tokenExpiry
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        snapshot = await BudgetService.shared.refresh()
        await loadTokenState()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Returns false when Coverflex sent an OTP code. Continue with `finishSignIn`.
    func startSignIn(email: String, password: String) async throws -> Bool {
        guard try await BudgetService.shared.startSignIn(email: email, password: password) else { return false }
        await didSignIn()
        return true
    }

    func finishSignIn(email: String, password: String, otp: String) async throws {
        try await BudgetService.shared.finishSignIn(email: email, password: password, otp: otp)
        await didSignIn()
    }

    private func didSignIn() async {
        await load()
        isSignInPresented = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    func signOut() async {
        await BudgetService.shared.signOut()
        await load()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
