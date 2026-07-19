//
//  ReportBugView.swift
//  Wander
//
//  In-app bug report / feedback. Sends a short description + auto-collected build & device info to
//  the Worker's /bugreport endpoint, which stores it in Firestore (viewable in the Firebase console)
//  and, when a Discord webhook is configured, pings the support channel. No account required; the
//  Apple-ID / Pro token is attached only if the user happens to be signed in, to help follow up.
//

import SwiftUI
import UIKit

struct ReportBugView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var contact = ""
    @State private var sending = false
    @State private var sent = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var diagnostics: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Wander \(v) (build \(b)) · iOS \(UIDevice.current.systemVersion) · \(Self.deviceModel())"
    }

    private var canSend: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && !sending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("What happened? Steps to reproduce help a lot.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .frame(minHeight: 130)
                            .focused($focused)
                    }
                } header: {
                    Text("Describe the bug or idea")
                }

                Section {
                    TextField("Discord username or email (optional)", text: $contact)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("So we can follow up if we need more info. Leave it blank to stay anonymous.")
                }

                Section {
                    Text(diagnostics)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Label("Recent diagnostic log attached (\(LogManager.shared.errorCount) errors)", systemImage: "doc.text.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Automatically included")
                } footer: {
                    Text("We attach your app version, device model, and a recent technical log (connection & error events) so we can reproduce the problem. Coordinates are stripped out — no location or personal data is sent.")
                }

                if let errorText {
                    Section {
                        Text(errorText).font(.caption).foregroundStyle(.orange)
                        if let discord = URL(string: "https://discord.gg/gfHdsRXUVA") {
                            Link("Or report it in our Discord", destination: discord).font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("Report a bug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Send") { send() }.disabled(!canSend)
                    }
                }
            }
            .overlay {
                if sent {
                    ContentUnavailableView {
                        Label("Report sent", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("Thanks for helping make Wander better — we read every report.")
                    } actions: {
                        Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                    .background(.background)
                }
            }
        }
    }

    private func send() {
        let description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard description.count >= 3 else { return }
        // Build the metadata here on the main actor (UIKit access), then hand it to the network task.
        let meta: [String: String] = [
            "platform": "iOS",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "os": "iOS \(UIDevice.current.systemVersion)",
            "device": Self.deviceModel(),
            "errorCount": String(LogManager.shared.errorCount),
        ]
        // The scrubbed recent log is what turns "still not working" into an actual diagnosis.
        let logs = LogManager.shared.recentLogTail()
        sending = true
        errorText = nil
        focused = false
        let contactValue = contact.trimmingCharacters(in: .whitespaces)
        Task {
            let ok = await Self.submit(description: description, contact: contactValue, meta: meta, logs: logs)
            sending = false
            if ok { withAnimation { sent = true } }
            else { errorText = "Couldn't send right now — check your connection and try again." }
        }
    }

    // MARK: - Networking

    private static let endpoint = "https://wander-payments.wanderlocation.workers.dev/bugreport"

    static func submit(description: String, contact: String, meta: [String: String], logs: String = "") async -> Bool {
        guard let url = URL(string: endpoint) else { return false }
        var body: [String: Any] = ["description": description, "contact": contact, "meta": meta]
        if !logs.isEmpty { body["logs"] = logs }
        if let token = await WanderProAccount.shared.currentIdToken() { body["idToken"] = token }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any]
            return status == 200 && (obj?["ok"] as? Bool == true)
        } catch {
            return false
        }
    }

    /// The hardware model identifier, e.g. "iPhone16,2" — more useful for repro than "iPhone".
    static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(validatingUTF8: ptr) ?? "unknown"
        }
    }
}
