import CoverflexCore
import SwiftUI

/// Two-step Coverflex sign-in, as in run-gmc
/// (https://github.com/gmcabrita/run-gmc/blob/49b8808/bin/coverflex-uat.ts):
/// 1. Email and password. Coverflex sends an OTP code and returns no tokens.
/// 2. Same request with the OTP code. Coverflex returns the access and refresh tokens.
/// `BudgetService` then trusts this client and stores the email, password, and user agent token
/// in the Keychain, so later logins need no OTP code.
/// Step 1 skips the OTP when a user agent token for the same email is already stored.
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

    var body: some View {
        Form {
            if case let .signInRequired(reason) = model.snapshot.problem, model.snapshot.balanceCents != nil {
                Section {
                    Label("Your Coverflex session expired. Sign in again to update the widget.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } footer: {
                    Text(reason)
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

                if model.isSignInPresented && model.hasSession && !model.snapshot.needsSignIn {
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
            if try await model.startSignIn(email: email.trimmingCharacters(in: .whitespaces), password: password) {
                resetForm()
            } else {
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
            try await model.finishSignIn(
                email: email.trimmingCharacters(in: .whitespaces),
                password: password,
                otp: otp.trimmingCharacters(in: .whitespaces)
            )
            resetForm()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetForm() {
        password = ""
        otp = ""
        step = .credentials
    }
}
