//
//  CrashReporter.swift
//  Wander
//
//  Best-effort automatic crash reporting. A process that's crashing can't reliably make a network
//  call, so we PERSIST a crash report to disk in the handler, then SEND it on the NEXT launch —
//  reusing the same Worker `/bugreport` pipeline the in-app "Report a bug" uses, so crashes land in
//  the Discord support channel automatically, no user action needed.
//
//  Catches uncaught Obj-C/Swift exceptions + the common fatal signals (SIGABRT/SIGSEGV/…). Handlers
//  are intentionally minimal (a crashing process is a hostile place to run code): the device header
//  is captured up-front at install time so the handler only appends the stack and writes a file.
//

import Foundation
import UIKit

enum CrashReporter {
    private static let fileURL = URL.documentsDirectory.appendingPathComponent("wander_pending_crash.txt")
    private static let endpoint = "https://wander-payments.wanderlocation.workers.dev/bugreport"

    /// Pre-rendered "build X · iOS Y · iPhoneZ" line, captured at install() so the crash handler
    /// never has to call UIKit (which isn't safe from a signal handler).
    nonisolated(unsafe) private static var deviceHeader = ""

    /// Install the handlers as early in launch as possible (before anything that might crash).
    static func install() {
        deviceHeader = "Wander crash — build \(Self.build()) · iOS \(UIDevice.current.systemVersion) · \(Self.model())\n\n"

        NSSetUncaughtExceptionHandler { exception in
            let report = "TYPE: Uncaught exception\nNAME: \(exception.name.rawValue)\nREASON: \(exception.reason ?? "(none)")\n\nSTACK:\n"
                + exception.callStackSymbols.prefix(28).joined(separator: "\n")
            CrashReporter.writeReport(report)
        }

        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGBUS, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                let report = "TYPE: Fatal signal \(s)\n\nSTACK:\n"
                    + Thread.callStackSymbols.prefix(28).joined(separator: "\n")
                CrashReporter.writeReport(report)
                signal(s, SIG_DFL)   // restore the default handler so the process actually terminates
                raise(s)
            }
        }
    }

    /// If the previous run left a crash report, send it to support and clear it. Call once on launch.
    static func sendPendingIfAny() {
        guard let report = try? String(contentsOf: fileURL, encoding: .utf8),
              !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? FileManager.default.removeItem(at: fileURL)
        let meta: [String: String] = [
            "platform": "iOS",
            "version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "",
            "build": Self.build(),
            "os": "iOS \(UIDevice.current.systemVersion)",
            "device": Self.model(),
            "errorCount": "crash",
        ]
        Task.detached { await Self.send(report: report, meta: meta) }
    }

    // MARK: - Internals

    private static func writeReport(_ report: String) {
        // Mid-crash: append pre-captured header + the stack and write once. Best-effort; matches how
        // lightweight crash reporters trade strict signal-safety for catching the majority of crashes.
        try? (deviceHeader + report).data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    private static func send(report: String, meta: [String: String]) async {
        guard let url = URL(string: endpoint) else { return }
        let body: [String: Any] = [
            "description": "💥 The app crashed on the previous launch (auto-reported — no user action).",
            "contact": "",
            "kind": "crash",
            "meta": meta,
            "logs": String(report.prefix(5500)),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        _ = try? await URLSession.shared.data(for: req)
    }

    private static func build() -> String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    private static func model() -> String {
        var sys = utsname(); uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(validatingUTF8: ptr) ?? "unknown"
        }
    }
}
