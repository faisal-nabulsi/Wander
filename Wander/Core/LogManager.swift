//
//  LogManager.swift
//  Wander
//
//  Created by neoarz on 3/29/25.
//

import Foundation

final class LogManager: ObservableObject {
    static let shared = LogManager()

    @Published var logs: [LogEntry] = []
    @Published var errorCount: Int = 0

    struct LogEntry: Identifiable, Sendable {
        let id: UUID
        let timestamp: Date
        let type: LogType
        let message: String

        enum LogType: String, Sendable {
            case info    = "INFO"
            case error   = "ERROR"
            case debug   = "DEBUG"
            case warning = "WARNING"
        }

        init(timestamp: Date, type: LogType, message: String) {
            self.id = UUID()
            self.timestamp = timestamp
            self.type = type
            self.message = message
        }
    }

    private static let redundantPrefixes: [String] = [
        "Info: ", "INFO: ", "Information: ",
        "Error: ", "ERROR: ", "ERR: ",
        "Debug: ", "DEBUG: ", "DBG: ",
        "Warning: ", "WARN: ", "WARNING: "
    ]

    private init() {
        addInfoLog("Wander starting up")
        addInfoLog("Initializing environment")
    }

    func addLog(message: String, type: LogEntry.LogType) {
        let clean = Self.redundantPrefixes
            .first(where: { message.hasPrefix($0) })
            .map { String(message.dropFirst($0.count)) } ?? message

        // DROP RAW BYTE-ARRAY SPAM BEFORE IT REACHES THE BUFFER.
        //
        // The idevice layer debug-prints plists (the pairing file, escrow bag, keys) one BYTE PER LINE.
        // A single pairing dump is thousands of entries, so with a 1000-entry buffer it evicted every
        // real event — which is exactly why four separate diagnostic captures came back containing
        // nothing but numbers, with the [spoof] trace already gone before Export could run. These lines
        // carry no diagnostic value: a byte of a key tells you nothing, and the surrounding context
        // lines are kept.
        if Self.isRawByteLine(clean) { return }

        DispatchQueue.main.async {
            self.logs.append(LogEntry(timestamp: Date(), type: type, message: clean))
            if type == .error { self.errorCount += 1 }
            if self.logs.count > 4000 { self.logs.removeFirst(500) }
        }
    }

    /// True for a line that is only a number (optionally with a trailing comma) — i.e. one element of a
    /// dumped Data array. Cheap enough to run on every log line.
    static func isRawByteLine(_ message: String) -> Bool {
        let t = message.trimmingCharacters(in: CharacterSet(charactersIn: " \t,"))
        guard !t.isEmpty else { return false }
        // ANY line that is nothing but digits. No length limit: a bare number carries no diagnostic
        // value whatever its size — there is no context, no label, nothing to correlate. Dropping the
        // whole class is simpler and more robust than guessing at byte-sized ones (the earlier <=3
        // version still let larger numeric dumps through).
        if t.allSatisfy(\.isNumber) { return true }
        // The scaffolding those dumps sit inside — bare brackets/parens on their own line.
        if t.count <= 2, t.allSatisfy({ "[](){}".contains($0) }) { return true }
        return false
    }

    func addInfoLog(_ message: String)    { addLog(message: message, type: .info) }
    func addErrorLog(_ message: String)   { addLog(message: message, type: .error) }
    func addDebugLog(_ message: String)   { addLog(message: message, type: .debug) }
    func addWarningLog(_ message: String) { addLog(message: message, type: .warning) }

    /// A compact, privacy-scrubbed tail of the recent log for attaching to bug reports — so support
    /// gets the real connection/mount/error trail (e.g. the tunnel failure behind a stuck setup)
    /// instead of guessing. High-precision decimals (potential coordinates) are redacted so a report
    /// never carries the user's location. Returns the last `maxEntries` events, newest last.
    func recentLogTail(maxEntries: Int = 80) -> String {
        let tail = logs.suffix(maxEntries)
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return tail.map { entry in
            // Redact anything shaped like a coordinate (signed decimal, 3+ fraction digits).
            let scrubbed = entry.message.replacingOccurrences(
                of: #"-?\d{1,3}\.\d{3,}"#, with: "[coord]", options: .regularExpression)
            return "\(df.string(from: entry.timestamp)) \(entry.type.rawValue) \(scrubbed)"
        }.joined(separator: "\n")
    }

    func setLogs(_ entries: [LogEntry]) {
        let kept = entries.filter { !Self.isRawByteLine($0.message) }
        DispatchQueue.main.async {
            self.logs = kept
            self.errorCount = kept.filter { $0.type == .error }.count
        }
    }

    // NOTE: the idevice log stream arrives HERE, in batches — not through addLog. Filtering only in
    // addLog did nothing for the byte-dump spam, which is exactly why it kept flooding the console after
    // the first attempt at this. Filter on every ingestion path, and raise the cap: a pairing-file dump
    // is thousands of entries and at 1000 it evicted every real event before it could be read.
    func appendLogs(_ entries: [LogEntry], maxTotal: Int = 4000) {
        let entries = entries.filter { !Self.isRawByteLine($0.message) }
        guard !entries.isEmpty else { return }
        DispatchQueue.main.async {
            self.logs.append(contentsOf: entries)
            self.errorCount += entries.filter { $0.type == .error }.count
            if self.logs.count > maxTotal {
                let excess = self.logs.count - maxTotal
                let removed = self.logs.prefix(excess)
                self.logs.removeFirst(excess)
                let removedErrors = removed.filter { $0.type == .error }.count
                self.errorCount = max(0, self.errorCount - removedErrors)
            }
        }
    }

    func clearLogs() {
        DispatchQueue.main.async {
            self.logs.removeAll()
            self.errorCount = 0
        }
    }
}
