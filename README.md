# Coverflex Budget

iOS app and Home Screen widget that show the Coverflex meal card balance.

- **App**: sign in with email, password, and OTP code. Stores the Coverflex tokens in the Keychain. Never stores the password.
- **Widget** (small): balance, refresh button, last update time.
  - Tap opens the Coverflex app (through `https://my.coverflex.com`, a Coverflex universal link).
  - When the session expired, tap opens this app at the sign-in form.
- **Shortcuts**: "Refresh Meal Budget" action. Updates the widget and returns the balance in euros. Fails when the session expired.

```mermaid
flowchart LR
  subgraph App process
    SignIn[SignInView] -->|tokens| Service1[BudgetService]
    Shortcut[Shortcuts / Automations] --> Intent1[RefreshMealBudgetIntent]
    Intent1 --> Service1
  end
  subgraph Widget extension
    Timeline[Timeline provider, every 30 min] --> Service2[BudgetService]
    Button[Refresh button] --> Intent2[RefreshMealBudgetIntent]
    Intent2 --> Service2
  end
  Service1 & Service2 -->|renew, pockets| API[(menhir-api.coverflex.com)]
  Service1 & Service2 <--> KC[(Keychain: tokens<br/>App Group access group)]
  Service1 & Service2 <--> UD[(App Group UserDefaults:<br/>BudgetSnapshot)]
  UD --> View[Widget view]
  View -->|tap, OK| App1[coverflexbudget://open-coverflex → Coverflex app]
  View -->|tap, sign-in needed| App2[coverflexbudget://sign-in → sign-in form]
```

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
- AltStore refreshes the signature every 7 days. The tokens and the snapshot stay on the device.

## Tests

Shared logic lives in `Packages/CoverflexCore` and runs on macOS:

```sh
cd Packages/CoverflexCore && swift test
```
