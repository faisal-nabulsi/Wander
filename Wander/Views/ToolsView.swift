//
//  ToolsView.swift
//  Wander
//
//  Created by Stephen on 2/23/26.
//

import SwiftUI

struct ToolsView: View {
    var body: some View {
        NavigationStack {
            List {
                ForEach(AppFeature.toolList) { tool in
                    NavigationLink {
                        tool.destination
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.toolTitle)
                                Text(tool.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: tool.systemImage)
                        }
                    }
                }

                // Not an AppFeature case on purpose: adding one means touching five switch statements
                // for a diagnostic screen, and this is a bench instrument rather than a feature.
                NavigationLink {
                    TunnelMatrixView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tunnel Matrix")
                            Text("Test every tunnel address plan in one run")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "tablecells")
                    }
                }

                // Same reasoning as the row above. This one is READ-ONLY — it starts no tunnel and
                // writes no setting — and it is the only way to reach the RPPairing handshake probe,
                // the scoped-socket probe and the cellular IPv6 carve, all of which shipped inside
                // the binary with no button attached to them.
                NavigationLink {
                    TunnelLabView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tunnel Lab")
                            Text("Read-only probes: interfaces, routes, handshake, socket scoping, IPv6")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "testtube.2")
                    }
                }
            }
            .navigationTitle("Tools")
        }
    }
}
