//
//  AddressSearchBar.swift
//  Wander
//
//  Reusable search field: type an address or place, pick a result, get a coordinate.
//  Used by Walk mode (set start) and Route mode (add waypoint).
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

@MainActor
final class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(_ query: String) {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = []
            completer.queryFragment = ""
        } else {
            completer.queryFragment = query
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let r = completer.results
        Task { @MainActor in self.results = r }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

struct AddressSearchBar: View {
    var placeholder: String = "Search address or place"
    /// Reference point used to recover *short* Plus Codes (e.g. "9G8F+6X").
    /// Full Plus Codes and plain coordinates don't need it. Typically the
    /// current map center.
    var mapCenter: CLLocationCoordinate2D? = nil
    var onPick: (CLLocationCoordinate2D, String) -> Void
    /// Fires true while the field is focused OR showing results, so a host can get out of the way
    /// (e.g. hide a floating top card that would otherwise cover the results list).
    var onActiveChange: ((Bool) -> Void)? = nil

    @StateObject private var completer = AddressSearchCompleter()
    @State private var query = ""
    @FocusState private var focused: Bool
    /// True when the clipboard PROBABLY holds something worth offering to paste.
    /// Set from `detectedPatterns`, which reports which KINDS of content are present
    /// without handing us the value — the one clipboard probe that never raises a
    /// prompt. We deliberately never learn the coordinate before the user taps
    /// Paste; see `pasteRow` for why that matters.
    @State private var clipboardMayHoldTarget = false
    /// Pasteboard generation we last probed. `changeCount` is free and prompt-free,
    /// so gating on it just avoids re-running the pattern detection for a clipboard
    /// that hasn't changed since we last looked.
    @State private var lastPasteboardChangeCount = -1
    /// Identity of the coordinate the local-time annotation is currently allowed to
    /// look up. It deliberately LAGS `parsedTarget` — see `targetRow`.
    @State private var settledClockKey: String?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.search)
                    .onChange(of: query) { _, newValue in completer.update(newValue) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        completer.update("")
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focused = false
                        // This keyboard toolbar can also show while a SIBLING field is focused (e.g.
                        // the "Where do you want to go?" bar), whose focus we don't own — so resign
                        // whatever is actually first responder instead of just our own field.
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }

            // A parsed coordinate always sits ABOVE the place-search results: if the
            // text really is a coordinate it's what the user meant, and the fuzzy
            // matches underneath are noise.
            if let target = parsedTarget {
                targetRow(target)
            } else if focused, clipboardMayHoldTarget,
                      query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // The whole point of this feature: people copy coordinates out of
                // Discord/Reddit posts. Only offered while the field is empty so it
                // can't clutter a search the user is actively typing.
                pasteRow
            }

            if !completer.results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(completer.results.prefix(6), id: \.self) { result in
                        Button { resolve(result) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).font(.subheadline).foregroundStyle(.primary)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(.horizontal, 10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused { probeClipboard() }
            reportActive()
        }
        .onChange(of: completer.results.count) { _, _ in reportActive() }
        .onChange(of: query) { _, _ in reportActive() }
        // The usual flow is "leave the app, copy a coordinate from Discord, come
        // back" — the field keeps focus across that trip, so `onChange(of: focused)`
        // never fires again and the offer would never appear for the exact case this
        // feature exists for. Re-probing here is safe precisely because `probeClipboard`
        // only asks WHAT KIND of content is on the pasteboard, never for its value:
        // it cannot raise a prompt, so foregrounding the app stays silent.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if focused { probeClipboard() }
        }
    }

    /// Active = the user is searching: focused, or there are results / a parsed target to show.
    private func reportActive() {
        onActiveChange?(focused || !completer.results.isEmpty || parsedTarget != nil)
    }

    /// One row for a parsed coordinate, styled like the place-search rows below it.
    /// Tapping goes through `commit`, i.e. the same `onPick` path a search result
    /// uses — there is deliberately no second teleport route.
    @ViewBuilder
    private func targetRow(_ target: ResolvedTarget) -> some View {
        let key = Self.clockKey(target.coordinate)
        Button { commit(target) } label: {
            HStack(spacing: 8) {
                Image(systemName: target.symbol).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Go to  %.5f, %.5f",
                                target.coordinate.latitude, target.coordinate.longitude))
                        .font(.subheadline).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        // Kept short because the destination's local time sits beside it
                        // on the same line.
                        Text(target.detail).font(.caption).foregroundStyle(.secondary)
                        // Same annotation the saved-place and hotspot rows carry, from the
                        // same shared cache (DestinationClock, PlacesView.swift): "what time
                        // is it THERE" is the question right before a hop across time zones.
                        // It draws nothing until the zone resolves, so an unknown coordinate
                        // leaves the row exactly as it was.
                        if settledClockKey == key {
                            DestinationLocalTimeLabel(coordinate: target.coordinate)
                        }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hold the clock back until the typing stops. Unlike the list rows this
        // annotation was built for, `parsedTarget` re-parses on every KEYSTROKE, and
        // the half-typed strings on the way to "40.7128, -74.0060" ("40.7128, -7",
        // "40.7128, -74.0") are themselves valid coordinates in different zones.
        // Handing each one to DestinationClock would spend the shared, aggressively
        // rate-limited CLGeocoder budget — which Places and the hotspot lists also
        // draw on — resolving points the user was only passing through.
        .task(id: key) {
            settledClockKey = nil
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            settledClockKey = key
        }
    }

    /// Identity for "which coordinate is the clock annotation showing". Five decimals
    /// matches the row's own printed precision, and `String(format:)` is deliberately
    /// unlocalized so this key can't change shape with the device's decimal separator.
    private static func clockKey(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f", c.latitude, c.longitude)
    }

    /// Hand a parsed coordinate to the host and reset the field, mirroring what
    /// `resolve(_:)` does for a tapped place-search result.
    private func commit(_ target: ResolvedTarget) {
        onPick(target.coordinate, target.name)
        query = ""
        completer.update("")
        focused = false
        // `clipboardMayHoldTarget` deliberately survives: it describes what is on the
        // clipboard, which a teleport didn't change, so re-focusing still offers it.
    }

    /// The clipboard offer. It is deliberately NOT a preview of the coordinate.
    ///
    /// Since iOS 16, any programmatic read of a pasteboard VALUE that another app put
    /// there raises a BLOCKING "Allow Paste?" alert — not the old transient banner —
    /// and this feature's whole premise is text copied from Discord or Reddit, i.e.
    /// always foreign-origin, i.e. always the alert. Showing "Paste 40.71280,
    /// -74.00600" would mean reading that value on mere focus, so simply tapping the
    /// search field would pop a modal on six different screens. A system PasteButton
    /// is the only control that hands us the string with no prompt at all, so the
    /// affordance has to be the button and the coordinate stays unknown until it's hit.
    private var pasteRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Paste from clipboard").font(.subheadline).foregroundStyle(.primary)
                Text("Coordinates, a map link or a Plus Code")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                acceptPastedText(text)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// A pasted string lands in the FIELD rather than teleporting on the spot: the
    /// parsed row above then shows the coordinate and its destination local time, so
    /// the user sees where they're about to be sent before it happens. It also means a
    /// paste that isn't a coordinate degrades into an ordinary place search instead of
    /// a dead end — which is what a paste into a search field should do anyway.
    private func acceptPastedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The clipboard can hold an entire article. Anything past the parser's own
        // length cap can't be a coordinate and would only wreck the field.
        guard !trimmed.isEmpty, trimmed.count <= 400 else {
            clipboardMayHoldTarget = false
            return
        }
        query = trimmed   // the field's own onChange drives the completer
    }

    /// Ask the pasteboard what KIND of content it holds — never for the content.
    /// `detectedPatterns` is documented as not giving the app access to the value, which
    /// is exactly why it's prompt-free and safe to call on focus or on foreground.
    private func probeClipboard() {
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount
        // `.number` covers a decimal pair and DMS; `.probableWebURL` covers a shared
        // Google/Apple Maps link. A bare Plus Code ("9G8F+6X") reliably matches
        // neither — the accepted blind spot, since offering the row for every copied
        // string would put it on screen permanently.
        // Note `detectedPatterns`, NOT the neighbouring `detectedValues`: same key
        // paths, but the latter hands back the content and is a read like any other.
        let patterns: Set<PartialKeyPath<UIPasteboard.DetectedValues>> = [\.number, \.probableWebURL]
        Task { @MainActor in
            let found = try? await pasteboard.detectedPatterns(for: patterns)
            clipboardMayHoldTarget = !(found ?? []).isEmpty
        }
    }

    private struct ResolvedTarget {
        let coordinate: CLLocationCoordinate2D
        let name: String
        let symbol: String
        /// How we read the text ("Exact coordinates", "Plus Code", …). Shown under
        /// the row so the user can tell a precise jump apart from a fuzzy place match.
        let detail: String
    }

    private var parsedTarget: ResolvedTarget? {
        Self.resolveTarget(from: query, reference: mapCenter)
    }

    // MARK: - Coordinate parsing
    //
    // These are `static` and take the text as a parameter rather than reading
    // `query` so they stay pure and independently testable: a parser that reaches
    // into view state can only be exercised by driving the view.

    /// Resolve anything a spoofer plausibly pastes — a decimal pair, DMS, a
    /// Google/Apple Maps link, or a Plus Code — to a coordinate. Returns nil for
    /// ordinary place names, which fall through to the normal place search.
    private static func resolveTarget(
        from text: String,
        reference: CLLocationCoordinate2D?
    ) -> ResolvedTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The length cap only exists because the clipboard can hold an entire
        // article; a coordinate in any accepted form is far shorter than this.
        guard !trimmed.isEmpty, trimmed.count <= 400 else { return nil }

        // Map links first. A Google URL can contain BOTH a '+' (place names use it
        // as a space) and a comma-separated number pair, so running it ahead of the
        // Plus Code and decimal parsers stops those two from misreading URL fragments.
        if let coord = coordinateFromMapLink(trimmed) {
            return ResolvedTarget(coordinate: coord, name: "Coordinates", symbol: "link", detail: "From a map link")
        }
        // Plus Codes next — a full code contains a '+' and OLC alphabet only, so it
        // won't collide with "lat,lng".
        if trimmed.contains("+"), PlusCode.isValid(trimmed.uppercased()),
           let coord = PlusCode.coordinate(from: trimmed, reference: reference) {
            return ResolvedTarget(coordinate: coord, name: "Plus Code", symbol: "plus.magnifyingglass", detail: "Plus Code")
        }
        if let coord = coordinateFromDMS(trimmed) {
            return ResolvedTarget(coordinate: coord, name: "Coordinates", symbol: "scope", detail: "Degrees, minutes, seconds")
        }
        if let coord = coordinateFromDecimalPair(trimmed) {
            return ResolvedTarget(coordinate: coord, name: "Coordinates", symbol: "scope", detail: "Exact coordinates")
        }
        return nil
    }

    /// "40.7128, -74.0060", "40.7128,-74.0060" or "40.7128 -74.0060".
    private static func coordinateFromDecimalPair(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text
            .split(whereSeparator: { $0 == "," || $0.isWhitespace || $0.isNewline })
            .filter { !$0.isEmpty }
        let nums = parts.compactMap { Double($0) }
        // Requiring the WHOLE string to be exactly two numbers is deliberate: a
        // house number followed by a street number must stay a place search.
        guard parts.count == 2, nums.count == 2 else { return nil }
        return validated(latitude: nums[0], longitude: nums[1])
    }

    /// Every character that can mark a degrees/minutes/seconds field, including the
    /// curly quotes an iOS keyboard substitutes for `'` and `"` when the coordinate
    /// was typed into a note or a chat before being copied.
    private static let dmsMarkers: Set<Character> = ["°", "'", "\"", "′", "″", "’", "”"]

    /// Degrees-minutes-seconds, e.g. `40°42'46.0"N 74°00'21.6"W`. Also accepts the
    /// hemisphere letter in front (`N 40°42'46.0"`), unicode primes, a missing
    /// seconds or minutes field, and E/W-first ordering.
    ///
    /// The hard part here isn't reading DMS, it's REFUSING everything else. This is a
    /// search bar: it sees "Macy's 34 W 7 Ave" far more often than it sees a real DMS
    /// pair, and an apostrophe plus two small street numbers is enough to look like
    /// one — range validation can't catch it because 34 and 7 are perfectly legal
    /// degrees. Both gates below exist for that, not for parsing.
    private static func coordinateFromDMS(_ text: String) -> CLLocationCoordinate2D? {
        let chars = Array(text.uppercased())

        // GATE 1 — a marker only counts when it DIRECTLY follows a digit. The
        // apostrophe in a possessive, a quoted place name and a stray prime anywhere
        // else are punctuation; admitting them is what let ordinary searches produce a
        // bogus "Go to" row. This also keeps the original purpose of the gate: with no
        // marker at all, "40 74" must fall through to the decimal parser.
        var isMarker = [Bool](repeating: false, count: chars.count)
        var sawMarker = false
        for i in chars.indices where dmsMarkers.contains(chars[i]) {
            guard i > 0, chars[i - 1].isNumber else { continue }
            isMarker[i] = true
            sawMarker = true
        }
        guard sawMarker else { return nil }

        // GATE 2 — an N/S/E/W is a hemisphere only if it stands alone AND touches a
        // real DMS field. Without this the S of "MACY'S", the W of a street name and
        // the E of "AVE" bind two unrelated numbers into a lat/lng pair.
        func isHemisphere(_ i: Int) -> Bool {
            guard "NSEW".contains(chars[i]) else { return false }
            // A letter on either side means we're inside a word, not reading a suffix.
            if i > 0, chars[i - 1].isLetter { return false }
            if i + 1 < chars.count, chars[i + 1].isLetter { return false }
            // Suffix form: the nearest thing to the left is a marker — `46.0"N`.
            var left = i - 1
            while left >= 0, chars[left].isWhitespace { left -= 1 }
            if left >= 0, isMarker[left] { return true }
            // Prefix form: a number follows, and that number is itself closed by a
            // marker — `N 40°42'`. Requiring the marker is what separates it from the
            // "S 34 …" of a possessive followed by a house number.
            var right = i + 1
            while right < chars.count, chars[right].isWhitespace { right += 1 }
            if right < chars.count, chars[right] == "-" { right += 1 }
            let numberStart = right
            while right < chars.count, chars[right].isNumber || chars[right] == "." { right += 1 }
            return right > numberStart && right < chars.count && isMarker[right]
        }

        // Walk the string once, collecting each hemisphere's numbers in order and
        // remembering which N/S/E/W letter goes with them. Everything else (°, ',
        // ", commas, spaces) is just punctuation between numbers.
        var groups: [(values: [Double], hemisphere: Character?)] = []
        var current: [Double] = []
        var pendingHemisphere: Character?
        var number = ""

        func flushNumber() {
            if let value = Double(number) { current.append(value) }
            number = ""
        }
        func closeGroup(trailing: Character?) {
            flushNumber()
            guard !current.isEmpty else { return }
            // A leading letter (prefix form) wins over the letter that closed the
            // group, since that one belongs to the NEXT half of the pair.
            groups.append((current, pendingHemisphere ?? trailing))
            current = []
            pendingHemisphere = pendingHemisphere == nil ? nil : trailing
        }

        for i in chars.indices {
            let ch = chars[i]
            if ch.isNumber || ch == "." {
                number.append(ch)
            } else if ch == "-", number.isEmpty {
                // The sign rides on the number string itself so it survives whichever
                // marker ends up closing the group.
                number = "-"
            } else if ch == "°", isMarker[i] {
                // Degrees always OPEN a half of the pair, so a *second* degree sign
                // means the previous half ended. This is the only thing that splits
                // "40°42'46\" -74°00'21.6\"" — the letter-less form has no other
                // boundary between the two halves.
                let carried = number
                number = ""
                if !current.isEmpty { closeGroup(trailing: nil) }
                number = carried
                flushNumber()
            } else if isHemisphere(i) {
                flushNumber()
                if current.isEmpty {
                    pendingHemisphere = ch
                } else {
                    closeGroup(trailing: ch)
                }
            } else {
                // Punctuation, a letter inside a word, or a marker that failed gate 1:
                // all of it merely ends whatever number was being read.
                flushNumber()
            }
        }
        closeGroup(trailing: nil)

        guard groups.count == 2 else { return nil }
        guard let first = degrees(from: groups[0].values),
              let second = degrees(from: groups[1].values) else { return nil }

        let firstHemisphere = groups[0].hemisphere
        let secondHemisphere = groups[1].hemisphere
        // "74°00'21.6\"W 40°42'46.0\"N" is written lng-first; honour the letters when
        // they're there, otherwise assume the conventional lat-then-lng order.
        let lngFirst = (firstHemisphere == "E" || firstHemisphere == "W")
        let latValue = lngFirst ? second : first
        let lngValue = lngFirst ? first : second
        let latHemisphere = lngFirst ? secondHemisphere : firstHemisphere
        let lngHemisphere = lngFirst ? firstHemisphere : secondHemisphere

        // Mixed-up letters (two N's, an N paired with an S) mean we misread it.
        if let latHemisphere, latHemisphere != "N" && latHemisphere != "S" { return nil }
        if let lngHemisphere, lngHemisphere != "E" && lngHemisphere != "W" { return nil }

        return validated(
            latitude: latHemisphere == "S" ? -latValue : latValue,
            longitude: lngHemisphere == "W" ? -lngValue : lngValue
        )
    }

    /// Fold a degrees/minutes/seconds triple (any of the trailing two optional) into
    /// decimal degrees. Rejects out-of-range minutes/seconds, which usually means we
    /// tokenised something that wasn't a coordinate at all.
    private static func degrees(from values: [Double]) -> Double? {
        guard (1...3).contains(values.count) else { return nil }
        let minutes = values.count > 1 ? values[1] : 0
        let seconds = values.count > 2 ? values[2] : 0
        guard (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
        // The sign lives on the degrees field, so add the fractions to its magnitude.
        let magnitude = abs(values[0]) + minutes / 60 + seconds / 3600
        return values[0] < 0 ? -magnitude : magnitude
    }

    /// Pull the coordinate out of a shared map link: Google's `/@lat,lng,zoom` and
    /// `?q=lat,lng`, Apple's `?ll=lat,lng`. Short links (maps.app.goo.gl) carry no
    /// coordinate and correctly return nil.
    private static func coordinateFromMapLink(_ text: String) -> CLLocationCoordinate2D? {
        let lower = text.lowercased()
        // Require it to actually look like a link, so a bare "40.7,-74.0" isn't run
        // through the URL markers first.
        guard lower.hasPrefix("http") || lower.contains("maps.apple.com")
                || lower.contains("google.") || lower.contains("goo.gl") else { return nil }
        // Shared links often percent-encode the comma ("q=40.7128%2C-74.0060").
        let haystack = (lower.removingPercentEncoding ?? lower)

        // Ordered by how specific the marker is: an explicit `ll=`/`q=` is the point
        // the sharer meant, whereas `@` is only the map's viewport centre.
        // `coordinate=` is Apple's newer /place link shape, which shares the same
        // Share sheet as `ll=` — without it half of Apple's own links silently
        // produce no row, which is the exact failure this feature exists to remove.
        for marker in ["ll=", "coordinate=", "q=", "query=", "daddr=", "center=", "@"] {
            var searchStart = haystack.startIndex
            while let range = haystack.range(of: marker, range: searchStart..<haystack.endIndex) {
                if let coord = leadingPair(haystack[range.upperBound...]) { return coord }
                // Keep scanning: `q=Statue+of+Liberty&ll=40.7,-74.0` has a q= that
                // isn't a coordinate but a usable pair further along.
                searchStart = range.upperBound
            }
        }
        return nil
    }

    /// Read a "lat,lng" pair off the front of a URL fragment, stopping at the first
    /// character that can't be part of a number pair (`&`, `/`, `z`, …).
    private static func leadingPair(_ fragment: Substring) -> CLLocationCoordinate2D? {
        var buffer = ""
        for ch in fragment {
            guard ch.isNumber || ch == "." || ch == "-" || ch == "," else { break }
            buffer.append(ch)
        }
        let parts = buffer.split(separator: ",")
        guard parts.count >= 2, let lat = Double(parts[0]), let lng = Double(parts[1]) else { return nil }
        return validated(latitude: lat, longitude: lng)
    }

    /// The single range gate for every parser above: anything outside real lat/lng
    /// bounds is dropped rather than teleporting the user somewhere wrong.
    private static func validated(latitude: Double, longitude: Double) -> CLLocationCoordinate2D? {
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            let coordinate = item.placemark.coordinate
            Task { @MainActor in onPick(coordinate, completion.title) }
        }
        query = ""
        completer.update("")
        focused = false
    }
}
