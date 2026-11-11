# Coverflex Budget

![Small widget: light mode, dark mode, and sign-in required](docs/images/widget.png)

iOS app and Home Screen widget that show the Coverflex meal card balance.

- **App**: sign in with email, password, and OTP code. After the OTP, the app trusts the device
  (`trust-user-agent`) and stores the email, password, user agent token, and session tokens in the Keychain.
- **Session**: same order as `run-gmc/src/coverflex/util`: stored access token, then renew with the refresh
  token, then login with email, password, and user agent token (no OTP) when Coverflex rejects the refresh
  token. Sign-in in the app is necessary only when Coverflex rejects that login. Temporary errors keep the session.
- **Widget** (small): balance, refresh button, last update time.
  - Tap opens the Coverflex app (through `https://my.coverflex.com`, a Coverflex universal link).
  - When the session expired, tap opens this app at the sign-in form.
- **Shortcuts**: "Refresh Meal Budget" action. Updates the widget and returns the balance in euros. Fails when the session expired.

```mermaid
flowchart LR
  subgraph App process
    SignIn[SignInView] -->|email, password, OTP| Service1[BudgetService]
    Shortcut[Shortcuts / Automations] --> Intent1[RefreshMealBudgetIntent]
    Intent1 --> Service1
  end
  subgraph Widget extension
    Timeline[Timeline provider, every 30 min] --> Service2[BudgetService]
    Button[Refresh button] --> Intent2[RefreshMealBudgetIntent]
    Intent2 --> Service2
  end
  Service1 & Service2 -->|renew, login, pockets| API[(menhir-api.coverflex.com)]
  Service1 & Service2 <--> KC[(Keychain: StoredSession<br/>credentials + tokens<br/>App Group access group)]
  Service1 & Service2 <--> UD[(App Group UserDefaults:<br/>BudgetSnapshot)]
  UD --> View[Widget view]
  View -->|tap, OK| App1[coverflexbudget://open-coverflex → Coverflex app]
  View -->|tap, sign-in needed| App2[coverflexbudget://sign-in → sign-in form]
```

## Widget design

The widget layout copies the Revolut balance widget. See [docs/widget-design.md](docs/widget-design.md)
for the measured values and `scripts/compare-widget.swift`, which measures widgets in a screenshot.
After design changes, update the README image with `swift scripts/render-widget-preview.swift`.

## Build

```sh
brew install xcodegen
xcodegen generate
open CoverflexBudget.xcodeproj
```

Signing uses team `5JCZ9B7BDM` (see `project.yml`). Xcode registers the bundle IDs and the
`group.com.gmcabrita.CoverflexBudget` App Group on the first device build.

## Install with AltStore or SideStore

```sh
./scripts/build-ipa.sh
```

Then install `build/CoverflexBudget.ipa` from AltStore ("My Apps" → "+").

- AltStore renames the App Group to `group.com.gmcabrita.CoverflexBudget.<TEAMID>` and writes the new
  name to `ALTAppGroups` in each `Info.plist`. `AppGroup.identifier` reads that key.
- The app uses 2 App IDs (app and widget) of the 10 that a free account can create in 7 days.
- AltStore refreshes the signature every 7 days. The session and the snapshot stay on the device.

## Tests

Shared logic lives in `Packages/CoverflexCore` and runs on macOS:

```sh
cd Packages/CoverflexCore && swift test
```
