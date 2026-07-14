//
//  GPXExport.swift
//  Wander
//
//  Minimal GPX 1.1 writer + a FileDocument so the current route/waypoints (or,
//  as a fallback, saved/recent places) can be written to a .gpx file via the
//  standard export sheet. Round-trips with CoordinateImportParser's importer.
//

import SwiftUI
import CoreLocation
import UniformTypeIdentifiers

enum GPXBuilder {
    /// Escape the five XML predefined entities.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func coord(_ value: Double) -> String {
        String(format: "%.7f", value)
    }

    /// Build a GPX document. If `route` has 2+ points it's written as a `<trk>`;
    /// any `waypoints` are written as `<wpt>` elements. Either may be empty.
    static func makeGPX(
        route: [CLLocationCoordinate2D] = [],
        waypoints: [(name: String, coordinate: CLLocationCoordinate2D)] = []
    ) -> String {
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<gpx version=\"1.1\" creator=\"Wander\" xmlns=\"http://www.topografix.com/GPX/1/1\">")

        for wpt in waypoints where CLLocationCoordinate2DIsValid(wpt.coordinate) {
            lines.append("  <wpt lat=\"\(coord(wpt.coordinate.latitude))\" lon=\"\(coord(wpt.coordinate.longitude))\">")
            if !wpt.name.isEmpty {
                lines.append("    <name>\(escape(wpt.name))</name>")
            }
            lines.append("  </wpt>")
        }

        let validRoute = route.filter { CLLocationCoordinate2DIsValid($0) }
        if validRoute.count >= 2 {
            lines.append("  <trk>")
            lines.append("    <name>Wander Route</name>")
            lines.append("    <trkseg>")
            for point in validRoute {
                lines.append("      <trkpt lat=\"\(coord(point.latitude))\" lon=\"\(coord(point.longitude))\"></trkpt>")
            }
            lines.append("    </trkseg>")
            lines.append("  </trk>")
        }

        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A document wrapping GPX text, for use with SwiftUI's `.fileExporter`.
struct GPXDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml]
    }
    static var writableContentTypes: [UTType] { readableContentTypes }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let string = String(data: data, encoding: .utf8) {
            text = string
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}
