import Foundation

/// URLs the widget uses to open this app. Widgets can only open their own app,
/// so the app forwards `.openCoverflex` to the Coverflex app.
/// The scheme must match `CFBundleURLSchemes` in `project.yml`.
public enum AppLink: String, Sendable, CaseIterable {
    /// Open the Coverflex app.
    case openCoverflex = "open-coverflex"
    /// Show the sign-in form.
    case signIn = "sign-in"

    public static let scheme = "coverflexbudget"

    /// Universal link handled by the Coverflex app (see https://my.coverflex.com/.well-known/apple-app-site-association).
    public static let coverflexWebURL = URL(string: "https://my.coverflex.com/")!

    public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host(), let link = AppLink(rawValue: host) else { return nil }
        self = link
    }

    /// Where a tap on the widget goes for this snapshot.
    /// An empty snapshot means the widget has never run a refresh, so the tap opens this app too.
    public static func widgetTap(for snapshot: BudgetSnapshot) -> AppLink {
        snapshot.needsSignIn || snapshot == BudgetSnapshot() ? .signIn : .openCoverflex
    }
}
