import CoverflexCore
import SwiftUI

/// Two-step Coverflex sign-in, as in `run-gmc/bin/coverflex-uat.ts`:
/// 1. Email and password. Coverflex sends an OTP code and returns no tokens.
/// 2. Same request with the OTP code. Coverflex returns the access and refresh tokens.
/// The password stays in memory only. The app stores the tokens, never the password.
struct SignInView: View {
    let model: AppModel

    private enum Step { case credentials, otp }
    private enum Field { case email, password, otp }

    @AppStorage("lastEmail") private var email = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var step = Step.credentials
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focus: Field?

    private let api = CoverflexAPI()

    var body: some View {
        Form {
            if model.snapshot.needsSignIn && model.snapshot.balanceCents != nil {
                Section {
                    Label("Your Coverflex session expired. Sign in again to update the widget.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await submitCredentials() } }
            } header: {
                Text("Coverflex account")
            }
            .disabled(step == .otp || isWorking)

            if step == .otp {
                Section {
                    TextField("Code", text: $otp)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .focused($focus, equals: .otp)
                } header: {
                    Text("Verification code")
                } footer: {
                    Text("Coverflex sent a code. If no code arrives, check the email and password.")
                }
                .disabled(isWorking)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { step == .credentials ? await submitCredentials() : await submitOTP() }
                } label: {
                    HStack {
                        Text(step == .credentials ? "Continue" : "Sign In")
                        if isWorking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isWorking || !canSubmit)

                if step == .otp {
                    Button("Start Over") {
                        step = .credentials
                        otp = ""
                        errorMessage = nil
                    }
                    .disabled(isWorking)
                }

                if model.isSignInPresented && model.hasTokens && !model.snapshot.needsSignIn {
                    Button("Cancel", role: .cancel) { model.isSignInPresented = false }
                }
            }
        }
        .onAppear { focus = email.isEmpty ? .email : .password }
    }

    private var canSubmit: Bool {
        switch step {
        case .credentials: !email.isEmpty && !password.isEmpty
        case .otp: !otp.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func submitCredentials() async {
        guard canSubmit, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            switch try await api.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password) {
            case let .signedIn(tokens):
                await finish(with: tokens)
            case .otpRequired:
                step = .otp
                focus = .otp
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submitOTP() async {
        guard canSubmit, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let tokens = try await api.signIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password,
                otp: otp.trimmingCharacters(in: .whitespaces)
            )
            await finish(with: tokens)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish(with tokens: AuthTokens) async {
        do {
            try await model.completeSignIn(with: tokens)
            password = ""
            otp = ""
            step = .credentials
        } catch {
            errorMessage = "Could not save the Coverflex session: \(error.localizedDescription)"
        }
    }
}
