//
//  WanderLoginView.swift
//  Wander
//
//  Apple-ID sign-in sheet for the self-refresh signing pipeline (M1). Email + password +
//  2FA. On success it just confirms the login; cert/profile/re-sign come later.
//

import SwiftUI

struct WanderLoginView: View {
    @ObservedObject private var account = WanderAccount.shared
    @Environment(\.dismiss) private var dismiss

    @State private var appleID = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Apple ID email", text: $appleID)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } header: {
                    Text("Apple ID")
                } footer: {
                    Text("Use a free Apple ID (a throwaway one is recommended). Wander logs in to Apple's servers to fetch a signing certificate. Your credentials are used only for this sign-in.")
                }

                Section {
                    Button {
                        busy = true
                        Task {
                            await account.signIn(appleID: appleID, password: password)
                            busy = false
                            if account.isSignedIn { dismiss() }
                        }
                    } label: {
                        HStack {
                            if busy {
                                ProgressView().controlSize(.small).padding(.trailing, 4)
                            }
                            Text(busy ? "Signing in…" : "Sign in")
                        }
                    }
                    .disabled(busy || appleID.isEmpty || password.isEmpty)

                    if !account.status.isEmpty {
                        Text(account.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Sign in to Apple ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Two-Factor Code", isPresented: $account.awaiting2FA) {
                TextField("6-digit code", text: $code)
                    .keyboardType(.numberPad)
                Button("Submit") {
                    account.submitTwoFactorCode(code.trimmingCharacters(in: .whitespaces))
                    code = ""
                }
                Button("Cancel", role: .cancel) {
                    account.submitTwoFactorCode(nil)
                    code = ""
                }
            } message: {
                Text("Enter the 6-digit code Apple sent to your trusted device. No popup? Get it from Settings → your name → Sign-In & Security → Get Verification Code.")
            }
        }
    }
}
