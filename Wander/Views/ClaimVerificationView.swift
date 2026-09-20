//
//  ClaimVerificationView.swift
//  Wander
//
//  Walks through the claims Wander's architecture rests on and shows, per claim, whether THIS device on
//  THIS iOS version actually confirms it. See SpoofClaims for why this exists.
//

import SwiftUI

struct ClaimVerificationView: View {
    @ObservedObject private var log = ExperimentLog.shared
    @State private var expanded: String?

    var body: some View {
        List {
            Section {
                Text("Everything Wander's design assumes, stated so it can be proved wrong. Each claim is checked against a real reading from this phone — nothing here is taken on trust.")
                    .font(.footnote).foregroundStyle(.secondary)
                let verified = SpoofClaims.all.filter { SpoofClaims.latestOutcome(for: $0, in: log.records) != nil }.count
                Text("\(verified) of \(SpoofClaims.all.count) checked on this device")
                    .font(.caption.bold())
                    .foregroundStyle(verified == SpoofClaims.all.count ? .green : .orange)
            }

            ForEach(SpoofClaims.all) { claim in
                Section {
                    Text(claim.statement)
                        .font(.footnote.weight(.medium))

                    statusRow(for: claim)

                    Button {
                        expanded = (expanded == claim.id) ? nil : claim.id
                    } label: {
                        Label(expanded == claim.id ? "Hide how to test" : "How to test",
                              systemImage: expanded == claim.id ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }

                    if expanded == claim.id {
                        Text("Why it matters: " + claim.stakes)
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.vertical, 2)
                        ForEach(Array(claim.setup.enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").font(.caption2)
                                Text(step).font(.caption2)
                            }
                        }
                        Text("Then: Location diagnostic → label it exactly “\(claim.captureLabel)” → Capture evidence.")
                            .font(.caption2.weight(.medium))
                            .padding(.top, 2)
                        Button {
                            UIPasteboard.general.string = claim.captureLabel
                        } label: {
                            Label("Copy the label", systemImage: "doc.on.doc").font(.caption2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Claim checks")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func statusRow(for claim: SpoofClaim) -> some View {
        if let (outcome, when) = SpoofClaims.latestOutcome(for: claim, in: log.records) {
            HStack {
                Image(systemName: icon(outcome)).foregroundStyle(color(outcome))
                VStack(alignment: .leading, spacing: 1) {
                    Text(text(outcome)).font(.caption.bold()).foregroundStyle(color(outcome))
                    Text("measured " + when.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text("Never checked on this device")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func icon(_ o: ClaimOutcome) -> String {
        switch o {
        case .pass: return "checkmark.seal.fill"
        case .fail: return "xmark.octagon.fill"
        case .inconclusive: return "exclamationmark.triangle.fill"
        }
    }
    private func color(_ o: ClaimOutcome) -> Color {
        switch o {
        case .pass: return .green
        case .fail: return .red
        case .inconclusive: return .orange
        }
    }
    private func text(_ o: ClaimOutcome) -> String {
        switch o {
        case .pass: return "CONFIRMED on this device"
        case .fail: return "FAILED — the claim is wrong here"
        case .inconclusive: return "Inconclusive — see the note on that capture"
        }
    }
}
