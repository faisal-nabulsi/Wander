//
//  PaywallView.swift
//  Wander
//
//  Shown as a non-dismissable cover when RemoteGate is locked and no valid license
//  is present. Lets a paying user paste a license key to unlock.
//

import SwiftUI

struct PaywallView: View {
    @ObservedObject private var gate = RemoteGate.shared
    @ObservedObject private var license = License.shared
    @State private var key = ""
    @State private var showError = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Wander.brand, Color(red: 0.05, green: 0.22, blue: 0.4)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.white)
                Text("Wander Pro")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text(gate.message.isEmpty
                     ? "Wander now requires a license to spoof your location. Enter your license key to unlock."
                     : gate.message)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 12) {
                    TextField("Paste your license key", text: $key)
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .foregroundStyle(.black)

                    if showError {
                        Label("That key isn't valid.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.yellow)
                    }

                    Button {
                        showError = !license.redeem(key)
                    } label: {
                        Text("Unlock")
                            .font(.headline)
                            .frame(maxWidth: .infinity).frame(height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(Wander.brand)
                    .controlSize(.large)
                }
                .padding(.horizontal, 32)

                Link("How to get a license", destination: URL(string: "https://github.com/faisal-nabulsi/Wander")!)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
            }
        }
        .interactiveDismissDisabled(true)
    }
}

#Preview {
    PaywallView()
}
