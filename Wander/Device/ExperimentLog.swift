//
//  ExperimentLog.swift
//  Wander
//
//  EVIDENCE, NOT ASSERTIONS.
//
//  This project has repeatedly built strategy on claims like "DVT sets isSimulatedBySoftware", "gs-loc
//  leaves it false", "locationd honors the in-app proxy" — each true, but each recorded as a sentence in
//  a note rather than as a measurement anyone can re-read. Twice, a research pass then "corrected" a
//  claim that had actually been measured, because the measurement left no artifact.
//
//  So: every experiment captures a full, timestamped snapshot of what the DEVICE actually reported —
//  the live CLLocation with all its metadata, which engine was active, and what the tunnel/VPN state
//  was — persisted across launches and exportable as text. If a claim is not in here, it is a
//  hypothesis, and it should be written down as one.
//

import Foundation
import CoreLocation

/// One captured measurement. Codable so the whole log survives relaunch and can be exported verbatim.
struct ExperimentRecord: Codable, Identifiable {
    var id = UUID()
    let timestamp: Date
    /// What the user was testing, e.g. "dual engine — cached gs-loc + DVT".
    let label: String
    let note: String

    // What Core Location actually reported. These are the numbers that settle arguments.
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let altitude: Double
    let verticalAccuracy: Double
    let speed: Double
    let course: Double
    /// nil = the OS supplied no sourceInformation at all, which is itself a meaningful result and must
    /// never be flattened into "false".
    let isSimulatedBySoftware: Bool?
    let isProducedByAccessory: Bool?
    let locationAgeSeconds: Double

    // Engine + transport state at the moment of capture, so a reading can never be misattributed to
    // the wrong configuration later.
    /// The coordinate Wander was actually PUSHING when this was captured, and how far the reported
    /// location was from it. THIS is what makes a capture self-validating: a spoof that is not moving
    /// the reported location is a no-op, and a no-op must never score PASS. Optional so older records
    /// still decode.
    let targetLatitude: Double?
    let targetLongitude: Double?
    let distanceFromTargetMeters: Double?

    let gslocModeEnabled: Bool
    let dualEngineEnabled: Bool
    let tunnelEndpointReachable: Bool
    let foreignVPNActive: Bool
    let proxyProbeRunning: Bool

    /// Says plainly whether the reported location actually landed on the pushed target. Without this a
    /// reader cannot tell a working spoof from a capture of the user's real location.
    var targetText: String {
        guard let tLat = targetLatitude, let tLng = targetLongitude else {
            return "  none pushed — nothing was being spoofed at capture time"
        }
        guard let d = distanceFromTargetMeters else { return "  \(tLat), \(tLng)" }
        let verdict = d <= 150 ? "ON TARGET" : "OFF TARGET — the spoof was NOT in effect"
        return String(format: "  target %.5f, %.5f\n  distance %.0f m  → %@", tLat, tLng, d, verdict)
    }

    /// Human-readable block for export. Deliberately verbose — this is meant to be pasted into a note
    /// or a message and still make sense months later.
    var exportText: String {
        let f = ISO8601DateFormatter()
        func flag(_ b: Bool?) -> String {
            guard let b else { return "nil (OS supplied no sourceInformation)" }
            return b ? "TRUE" : "FALSE"
        }
        return """
        ─────────────────────────────────────────
        \(label)
        \(f.string(from: timestamp))
        \(note.isEmpty ? "" : "note: " + note + "\n")
        LOCATION REPORTED BY CORE LOCATION
          coordinate           \(latitude), \(longitude)
          horizontalAccuracy   \(horizontalAccuracy) m
          altitude             \(altitude) m
          verticalAccuracy     \(verticalAccuracy) m
          speed                \(speed) m/s
          course               \(course)°
          age                  \(String(format: "%.1f", locationAgeSeconds)) s

        SOURCE FLAGS
          isSimulatedBySoftware  \(flag(isSimulatedBySoftware))
          isProducedByAccessory  \(flag(isProducedByAccessory))

        SPOOF TARGET
        \(targetText)

        ENGINE / TRANSPORT STATE
          gs-loc (PoGo) mode     \(gslocModeEnabled ? "ON" : "off")
          dual engine            \(dualEngineEnabled ? "ON" : "off")
          DVT endpoint reachable \(tunnelEndpointReachable ? "yes" : "NO")
          foreign VPN up         \(foreignVPNActive ? "yes" : "no")
          in-app proxy running   \(proxyProbeRunning ? "yes" : "no")
        """
    }
}

/// Append-only store. Small by nature (a session is a handful of captures), so a single JSON file in
/// Application Support is the right amount of machinery.
@MainActor
final class ExperimentLog: ObservableObject {
    static let shared = ExperimentLog()

    @Published private(set) var records: [ExperimentRecord] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wander-experiments.json")
    }()

    private init() { load() }

    func add(_ record: ExperimentRecord) {
        records.insert(record, at: 0)
        save()
    }

    func delete(_ record: ExperimentRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    /// The whole log as one pasteable document, newest first.
    var fullExport: String {
        guard !records.isEmpty else { return "No experiments recorded." }
        let header = """
        WANDER EXPERIMENT LOG
        \(records.count) record(s), newest first
        Exported \(ISO8601DateFormatter().string(from: Date()))

        """
        return header + records.map(\.exportText).joined(separator: "\n\n")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ExperimentRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Capture

extension ExperimentLog {
    /// Snapshot the live CLLocation plus every piece of engine state. Called from the diagnostic screen,
    /// where a CLLocationManager is already delivering updates.
    ///
    /// `location` MUST come from the live `didUpdateLocations` feed, not from `manager.location` — the
    /// cached property has been observed to disagree with the live feed (Apple forum thread 741248), and
    /// the live feed is what apps like Pokémon GO actually consume.
    static func capture(location: CLLocation,
                        label: String,
                        note: String = "",
                        proxyRunning: Bool = false) -> ExperimentRecord {
        let src = location.sourceInformation
        // What Wander is currently pushing. nil means no spoof is armed at all, which by itself
        // invalidates any claim about what a spoof reports.
        let target = GslocMode.currentTargetSnapshot
        return ExperimentRecord(
            timestamp: Date(),
            label: label,
            note: note,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            altitude: location.altitude,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            course: location.course,
            isSimulatedBySoftware: src?.isSimulatedBySoftware,
            isProducedByAccessory: src?.isProducedByAccessory,
            locationAgeSeconds: -location.timestamp.timeIntervalSinceNow,
            targetLatitude: target?.lat,
            targetLongitude: target?.lng,
            distanceFromTargetMeters: target.map { t in
                location.distance(from: CLLocation(latitude: t.lat, longitude: t.lng))
            },
            gslocModeEnabled: GslocMode.enabled,
            dualEngineEnabled: GslocMode.dualEngine,
            tunnelEndpointReachable: isTunnelSimEndpointReachable(),
            foreignVPNActive: WanderTunnel.foreignVPNInterfaceActive(),
            proxyProbeRunning: proxyRunning
        )
    }
}
