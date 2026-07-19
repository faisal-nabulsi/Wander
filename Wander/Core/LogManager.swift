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

        DispatchQueue.main.async {
            self.logs.append(LogEntry(timestamp: Date(), type: type, message: clean))
            if type == .error { self.errorCount += 1 }
            if self.logs.count > 1000 { self.logs.removeFirst(100) }
        }
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
        DispatchQueue.main.async {
            self.logs = entries
            self.errorCount = entries.filter { $0.type == .error }.count
        }
    }

    func appendLogs(_ entries: [LogEntry], maxTotal: Int = 1000) {
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
