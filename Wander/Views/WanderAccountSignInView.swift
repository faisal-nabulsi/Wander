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
    /// Called after a successful sign-in/sign-up so the presenter can dismiss the whole paywall.
    var onSuccess: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var account = WanderProAccount.shared

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorText = ""

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
            if account.isPro {
                onSuccess?()
                dismiss()
            } else {
                // Show whatever the service reported (wrong password, not-pro, network, …).
                let status = account.status
                errorText = status.isEmpty
                    ? "Couldn't unlock Pro with that account."
                    : status.replacingOccurrences(of: "❌ ", with: "")
            }
        }
    }
}

#Preview {
    WanderAccountSignInView()
}
