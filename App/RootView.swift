import CoverflexCore
import SwiftUI

struct RootView: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if model.showsSignIn {
                    SignInView(model: model)
                } else {
                    BudgetView(model: model)
                }
            }
            .navigationTitle("Coverflex Budget")
        }
        .task(id: scenePhase) {
            // The widget and Shortcuts can change the snapshot while the app is in the background.
            if scenePhase == .active { await model.load() }
        }
    }
}

/// Shares a plain text report for diagnosis. The report holds no tokens or credentials.
struct ExportDebugInfoButton: View {
    let model: AppModel

    var body: some View {
        ShareLink(item: model.debugReport, subject: Text("Coverflex Budget debug info")) {
            Label("Export Debug Info", systemImage: "ladybug")
        }
    }
}

struct BudgetView: View {
    let model: AppModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Meal budget").font(.subheadline).foregroundStyle(.secondary)
                    if let cents = model.snapshot.balanceCents {
                        AmountText(
                            amount: BudgetFormatting.format(cents: cents),
                            wholeFont: .system(size: 44, weight: .bold),
                            restFont: .system(size: 28)
                        )
                    } else {
                        Text("No data yet").font(.title2.bold())
                    }
                    if let fetchedAt = model.snapshot.fetchedAt {
                        Text("Updated \(fetchedAt, format: .relative(presentation: .named))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            if case let .fetchFailed(message) = model.snapshot.problem {
                Section("Last refresh failed") {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await model.refresh() }
                } label: {
                    HStack {
                        Label("Refresh", systemImage: "arrow.clockwise")
                        if model.isRefreshing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(model.isRefreshing)
            }

            Section("Session") {
                LabeledContent("Access token expires", value: Self.label(model.accessTokenExpiry))
                LabeledContent("Refresh token expires", value: Self.label(model.refreshTokenExpiry))
            }

            if let issue = model.lastRenewIssue {
                Section("Last renew issue") {
                    LabeledContent("Time", value: issue.date.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Started by", value: issue.trigger.rawValue)
                    LabeledContent("Refresh token changed", value: issue.refreshTokenChangedDuringRequest.map { $0 ? "Yes" : "No" } ?? "Unknown")
                    LabeledContent("Next step", value: issue.nextStep)
                    Text(issue.error).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }

            Section {
                ExportDebugInfoButton(model: model)
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    Task { await model.signOut() }
                }
            } footer: {
                Text("Add the widget from the Home Screen. Use the “Refresh Meal Budget” action in Shortcuts to build automations.")
            }
        }
        .refreshable { await model.refresh() }
    }

    private static func label(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
    }
}
