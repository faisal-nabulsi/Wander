//
//  WanderAccountSignInView.swift
//  Wander
//
//  Sheet for the OPTIONAL account-based Pro unlock (WanderProAccount). Someone who bought Pro
//  on wanderspoofer.com (or the Android app) signs into the same account here and the app
//  becomes Pro — no license key to paste. Presented from the paywall's "Already bought…" button.
//
//  On success the account's entitlement is read, License.isLicensed recomputes, and we dismiss.
//  It never touches the offline-key path; it's purely additive.
//

import SwiftUI

struct WanderAccountSignInView: View {
    /// "Continue with Apple" is fully BUILT but hidden until the Apple provider is enabled in
    /// Firebase (which requires the $99/yr Apple Developer Program). Flip to `true` to show it.
    private static let appleSignInEnabled = false

    /// Called after a successful sign-in/sign-up so the presenter can dismiss the whole paywall.
    var onSuccess: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var account = WanderProAccount.shared

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorText = ""

    // Forgot-password alert (used only when the email field is empty and we need to ask for one).
    @State private var showResetPrompt = false
    @State private var resetEmail = ""

    // Two-factor code alert — shown when a 2FA-enrolled account signs in and the service asks for
    // the current 6-digit authenticator code (WanderProAccount.mfaRequired).
    @State private var showMfaPrompt = false
    @State private var mfaCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    SecureField("Password", text: $password)
                        .textContentType(.password)

                    Button("Forgot password?") {
                        let typed = email.trimmingCharacters(in: .whitespacesAndNewlines)
                        if typed.isEmpty {
                            // No email typed yet — ask for one via an alert prompt.
                            resetEmail = ""
                            showResetPrompt = true
                        } else {
                            sendReset(to: typed)
                        }
                    }
                    .font(.footnote)
                    .tint(Wander.brand)
                    .disabled(busy)
                } header: {
                    Text("Wander account")
                } footer: {
                    if !errorText.isEmpty {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        submit { await account.signIn(email: email, password: password) }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "Signing in…" : "Sign in").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)

                    Button {
                        submit { await account.signUp(email: email, password: password) }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Create account")
                            Spacer()
                        }
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                }
                .tint(Wander.brand)

                Section {
                    // "or" divider between the email form and the Google button.
                    HStack {
                        VStack { Divider() }
                        Text("or")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        VStack { Divider() }
                    }
                    .listRowBackground(Color.clear)

                    Button {
                        submit { await account.signInWithGoogle() }
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "g.circle.fill")
                            Text("Continue with Google").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(busy)
                    .tint(Wander.brand)

                    if Self.appleSignInEnabled {
                        Button {
                            submit { await account.signInWithApple() }
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "apple.logo")
                                Text("Continue with Apple").fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .disabled(busy)
                        .tint(.black)
                    }
                }

                Section {
                    Text("Manage your account at wanderspoofer.com")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(busy)
                }
            }
            .alert("Reset password", isPresented: $showResetPrompt) {
                TextField("Email", text: $resetEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                Button("Send reset link") {
                    sendReset(to: resetEmail.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .disabled(resetEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enter your account email and we'll send a password reset link.")
            }
            .alert("Two-factor code", isPresented: $showMfaPrompt) {
                TextField("6-digit code", text: $mfaCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("Verify") {
                    verifyMfa(code: mfaCode)
                }
                .disabled(mfaCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {
                    account.cancelMfa()
                    mfaCode = ""
                }
            } message: {
                Text("Enter the 6-digit code from your authenticator app.")
            }
            // When the service raises the 2FA challenge (or a retry reopens it), show the prompt.
            .onChange(of: account.mfaRequired) { _, required in
                if required {
                    mfaCode = ""
                    showMfaPrompt = true
                }
            }
        }
    }

    /// Fire the password reset for `mail`, surfacing the service's confirmation/error in the footer.
    private func sendReset(to mail: String) {
        guard !mail.isEmpty else { return }
        errorText = ""
        busy = true
        Task {
            _ = await account.sendPasswordReset(email: mail)
            busy = false
            // Show whatever the service reported (confirmation or error), stripped of the ❌ marker.
            errorText = account.status.replacingOccurrences(of: "❌ ", with: "")
        }
    }

    /// Submit the 6-digit 2FA code entered in the prompt. On success the account adopts a real
    /// session (handled below); on failure the service keeps `mfaRequired` true and sets a friendly
    /// status, so we surface it in the footer and re-open the code prompt for another try.
    private func verifyMfa(code: String) {
        errorText = ""
        busy = true
        Task {
            await account.submitMfaCode(code)
            busy = false
            mfaCode = ""
            if account.isPro {
                onSuccess?()
                dismiss()
            } else if account.isSignedIn {
                // Verified, but this account simply isn't Pro yet.
                let status = account.status
                errorText = status.isEmpty
                    ? "Signed in, but this account isn't Pro yet."
                    : status.replacingOccurrences(of: "❌ ", with: "")
            } else if account.mfaRequired {
                // Wrong/expired code — the challenge is still open. Show why and let them retry.
                errorText = account.status.replacingOccurrences(of: "❌ ", with: "")
                showMfaPrompt = true
            } else {
                // Challenge was dropped (e.g. session expired) — surface the reason.
                let status = account.status
                errorText = status.isEmpty ? "" : status.replacingOccurrences(of: "❌ ", with: "")
            }
        }
    }

    /// Run an auth action, then decide success by whether the account is now Pro. If the
    /// credentials were valid but the account simply isn't Pro yet, we surface that instead of
    /// dismissing into an unchanged (still-locked) app.
    private func submit(_ action: @escaping () async -> Void) {
        errorText = ""
        busy = true
        Task {
            await action()
            busy = false
            // A 2FA-enrolled account isn't signed in yet — the service raised an MFA challenge and
            // the .onChange(of: account.mfaRequired) handler opens the code prompt. Don't treat this
            // as a failure or clobber the "enter your code" status.
            if account.mfaRequired {
                return
            }
            if account.isPro {
                onSuccess?()
                dismiss()
            } else if account.isSignedIn {
                // Credentials were valid but this account simply isn't Pro yet — say so.
                let status = account.status
                errorText = status.isEmpty
                    ? "Signed in, but this account isn't Pro yet."
                    : status.replacingOccurrences(of: "❌ ", with: "")
            } else {
                // Not signed in. Show whatever the service reported (wrong password, network, a
                // Google error…). An EMPTY status here means a quiet cancel — leave it silent.
                let status = account.status
                errorText = status.isEmpty
                    ? ""
                    : status.replacingOccurrences(of: "❌ ", with: "")
            }
        }
    }
}

#Preview {
    WanderAccountSignInView()
}
