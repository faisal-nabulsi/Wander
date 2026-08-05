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

/// Where a place search should be centred, and what to call that place out loud.
///
/// This exists because MapKit's default is exactly wrong for this app. An
/// `MKLocalSearchCompleter` with no region set ranks results around where the
/// PHONE PHYSICALLY IS. In a spoofer that is the one place the user is not
/// interested in: teleport to Tokyo, search "coffee", and without an anchor you
/// get a café near the user's couch. Every search surface therefore hands the
/// completer an explicit anchor and says so on screen.
struct MapSearchAnchor: Equatable {
    let coordinate: CLLocationCoordinate2D
    /// What to show in the "results near …" header. A place name once one is
    /// known, otherwise an honest role ("your pin", "the map view").
    let name: String
    /// Roughly how far around `coordinate` results should be preferred — a 100 km
    /// box at the default.
    ///
    /// Sized for "the metro area I am pretending to be in", not for the pin itself.
    /// The region is a hard filter (`regionPriority = .required`), so too tight a box
    /// turns an ordinary search for the next town over into a miss; too wide and
    /// "coffee" stops meaning coffee near here. Anything genuinely outside it is
    /// caught by `AnchoredPlaceCompleter`'s worldwide retry, so this number only
    /// decides how often the user is told the search widened — not whether far-away
    /// places are findable at all.
    var radiusMeters: CLLocationDistance = 50_000
    /// True when this anchor is the device's REAL location rather than the spoof
    /// target. Drives which way the "search near …" escape hatch points.
    var isRealLocation: Bool = false

    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: radiusMeters * 2,
            longitudinalMeters: radiusMeters * 2
        )
    }

    /// Identity used to decide whether the completer's region actually needs
    /// re-applying. Coarse on purpose (~1 km): panning the map a few metres must
    /// not restart the autocomplete query on every frame.
    var regionKey: String {
        String(format: "%.2f,%.2f,%.0f,%d",
               coordinate.latitude, coordinate.longitude, radiusMeters, isRealLocation ? 1 : 0)
    }

    static func == (lhs: MapSearchAnchor, rhs: MapSearchAnchor) -> Bool {
        lhs.regionKey == rhs.regionKey && lhs.name == rhs.name
    }
}

/// Best-effort human name for an anchor coordinate, so the header can say
/// "results near Shibuya" instead of "results near your pin".
///
/// Deliberately tiny and heavily gated: CLGeocoder is a shared, rate-limited
/// resource that Places and the destination-clock labels also draw on. One lookup
/// per ~1 km cell, cached for the life of the process, only started when a search
/// field is actually focused. A miss is not an error — the caller keeps its own
/// honest fallback name.
@MainActor
final class SearchAnchorNames: ObservableObject {
    static let shared = SearchAnchorNames()
    private init() {}

    @Published private(set) var names: [String: String] = [:]
    /// Cells we have already asked about and got nothing usable for — including
    /// outright failures. A miss is cached exactly like a hit, because the entire
    /// point of this class is to spend as little of the shared, rate-limited
    /// CLGeocoder budget as possible: without a negative entry, a cell that fails
    /// once re-fires a request every time a search field is focused, forever,
    /// against the same budget the caching exists to protect.
    private var misses: Set<String> = []
    private var inFlight: Set<String> = []
    /// Insertion order of decided cells (hit or miss) so the cache can be capped.
    /// Per entry this is tiny, but "for the life of the process" plus a user who
    /// pans a lot is still unbounded growth.
    private var order: [String] = []
    private static let maxEntries = 64
    private let geocoder = CLGeocoder()

    static func key(_ coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
    }

    func name(for coordinate: CLLocationCoordinate2D) -> String? {
        names[Self.key(coordinate)]
    }

    func resolve(_ coordinate: CLLocationCoordinate2D) {
        let key = Self.key(coordinate)
        guard names[key] == nil, !misses.contains(key), !inFlight.contains(key) else { return }
        inFlight.insert(key)
        Task { [weak self] in
            guard let self else { return }
            let placemarks = try? await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            inFlight.remove(key)
            // Neighbourhood first, then city, then country — whichever is the most
            // specific thing that actually came back.
            let resolved = placemarks?.first.flatMap { placemark in
                placemark.subLocality
                    ?? placemark.locality
                    ?? placemark.administrativeArea
                    ?? placemark.country
            }
            record(key, name: (resolved?.isEmpty == false) ? resolved : nil)
        }
    }

    /// Commit a decision for `key` — a name, or `nil` meaning "there is no name for
    /// this cell, stop asking" — and evict the oldest decisions past the cap.
    private func record(_ key: String, name: String?) {
        if let name {
            names[key] = name
        } else {
            misses.insert(key)
        }
        order.append(key)
        while order.count > Self.maxEntries {
            let oldest = order.removeFirst()
            names.removeValue(forKey: oldest)
            misses.remove(oldest)
        }
    }
}

/// Autocomplete that ranks results around a chosen place instead of around the
/// phone — with a worldwide escape hatch when that place has no answer.
///
/// Two completers, not one, and the reason is the whole design:
///
/// * `anchored` uses `regionPriority = .required`, which MapKit takes literally —
///   a result that is not inside the region is not returned AT ALL. That is
///   exactly right for "coffee" (rank it around Shibuya, not the user's couch) and
///   exactly wrong for "Eiffel Tower" typed while the pin sits in Tokyo, which is
///   the app's PRIMARY flow: teleporting somewhere far away. Required alone would
///   hand the user an empty dropdown with no way out.
/// * `worldwide` is a second, permanently unanchored completer. When the anchored
///   one comes back empty for a query the user is actually typing, the same text
///   is re-asked with no region at all and `didFallBackToWorldwide` goes true so
///   the UI can say so out loud rather than silently widening the search.
///
/// The automatic retry is not enough on its own, which is why `setForceWorldwide`
/// exists. It only fires on ZERO results, and a required region very often returns
/// something rather than nothing: type "Paris" against a Tokyo anchor and MapKit is
/// happy to offer a Shibuya bakery called "Paris Croissant". The list is non-empty,
/// the retry never runs, and the actual city — the thing the user is trying to
/// teleport to — is unreachable through the only place-name path the app has. So the
/// user gets a switch as well as a safety net.
///
/// A second completer rather than re-pointing the first one is deliberate: it
/// removes any dependence on whether re-assigning an unchanged `queryFragment`
/// restarts a search, and a late reply from the completer we are no longer
/// listening to is dropped by identity instead of racing the region swap.
@MainActor
final class AnchoredPlaceCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    /// True when `results` came from the unanchored retry because the anchor had
    /// nothing. Drives the honest header — never silently widen a search.
    @Published private(set) var didFallBackToWorldwide = false
    /// True while the user has explicitly ASKED to search the whole world. Kept
    /// separate from `didFallBackToWorldwide` because one is a choice and the other
    /// is a rescue: the header must not tell someone who deliberately widened the
    /// search that there was "nothing near" their pin.
    @Published private(set) var isForcedWorldwide = false

    private let anchored = MKLocalSearchCompleter()
    private let worldwide = MKLocalSearchCompleter()
    private var anchor: MapSearchAnchor?
    /// The last query the anchored completer answered, and what it answered with.
    ///
    /// This is what makes the worldwide switch two-way. Coming back from worldwide to
    /// the anchor with the SAME text otherwise depends on whether re-assigning an
    /// unchanged `queryFragment` restarts a search — undocumented, and if it doesn't,
    /// the user lands on a permanently empty list. Replaying the answer we already had
    /// makes the return instant and certain; a fresh reply, if one comes, just
    /// overwrites it with the same thing.
    private var anchoredFragment: String?
    private var anchoredResults: [MKLocalSearchCompletion] = []
    /// Region identity currently applied, so re-applying an unchanged region can't
    /// restart an in-flight query.
    private var appliedRegionKey: String?
    /// Latest text the user has typed, trimmed.
    private var query = ""
    /// The query the anchored completer drew a blank on. While the user keeps
    /// EXTENDING that text we stay worldwide, so refining "Eiffel Tow" → "Eiffel
    /// Tower" doesn't pay for a doomed anchored round-trip on every keystroke.
    /// Cleared the moment the text stops matching, or the anchor changes.
    private var worldwidePrefix: String?

    override init() {
        super.init()
        for completer in [anchored, worldwide] {
            completer.delegate = self
            completer.resultTypes = [.address, .pointOfInterest]
        }
        worldwide.region = MKCoordinateRegion(MKMapRect.world)
        if #available(iOS 18.0, *) { worldwide.regionPriority = .default }
    }

    /// Point the completer at `anchor`. `nil` restores MapKit's own behaviour
    /// (whole world, device-biased ranking) for callers that have no anchor.
    func setAnchor(_ newAnchor: MapSearchAnchor?) {
        let key = newAnchor?.regionKey
        guard key != appliedRegionKey else { return }
        appliedRegionKey = key
        anchor = newAnchor
        if let newAnchor {
            anchored.region = newAnchor.region
            // `.required`, not `.default`: `.default` treats the region as a mere
            // hint and MapKit is free to fall back to device-local results, which
            // is the exact bug this class exists for. The cost of taking it
            // literally — no answer for a far-away place — is paid by the
            // worldwide retry in `ingest`, not by the user.
            if #available(iOS 18.0, *) { anchored.regionPriority = .required }
        } else {
            anchored.region = MKCoordinateRegion(MKMapRect.world)
            if #available(iOS 18.0, *) { anchored.regionPriority = .default }
        }
        // Whatever the anchored completer last said was about a different region.
        anchoredFragment = nil
        anchoredResults = []
        // An explicit "search anywhere" outlives a pan or a teleport — it is a
        // statement about the SEARCH, not about the map. Re-anchoring underneath it
        // would silently drag the user back into the region they just stepped out of.
        guard !isForcedWorldwide else { return }
        // A new anchor is a new question: ask it anchored first, even if the last
        // one had fallen back.
        worldwidePrefix = nil
        didFallBackToWorldwide = false
        // Re-run whatever is already typed against the new region, otherwise the
        // list keeps showing results ranked for the previous anchor.
        if !query.isEmpty { anchored.queryFragment = query }
    }

    /// Turn the anchor off (or back on) by hand.
    ///
    /// The escape hatch for the case the automatic retry cannot see: a required
    /// region that returns SOMETHING irrelevant rather than nothing. Without this the
    /// only way to reach a far-away place would be to hope the anchor draws a
    /// complete blank.
    func setForceWorldwide(_ forced: Bool) {
        guard forced != isForcedWorldwide else { return }
        isForcedWorldwide = forced
        guard !query.isEmpty else {
            worldwidePrefix = forced ? "" : nil
            results = []
            didFallBackToWorldwide = false
            return
        }
        if forced {
            worldwidePrefix = query
            results = []
            didFallBackToWorldwide = true
            worldwide.queryFragment = query
            return
        }
        worldwidePrefix = nil
        didFallBackToWorldwide = false
        if anchoredFragment == query {
            // We already know what the anchor says about this exact text. An empty
            // answer is the same dead end the automatic retry exists for, so route it
            // straight back out rather than showing a blank list under an anchored
            // header.
            if anchoredResults.isEmpty, anchor != nil {
                startWorldwideRetry()
            } else {
                results = anchoredResults
            }
            return
        }
        results = []
        anchored.queryFragment = query
    }

    /// Drop the current suggestions and stop both completers. Used when a result is
    /// taken (the question has been answered) or the field is emptied.
    ///
    /// Also drops an explicit "search anywhere": that widening was about the question
    /// just answered, and the honest default for the NEXT one is the anchor again.
    func clearResults() {
        results = []
        didFallBackToWorldwide = false
        isForcedWorldwide = false
        worldwidePrefix = nil
        anchoredFragment = nil
        anchoredResults = []
        query = ""
        anchored.queryFragment = ""
        worldwide.queryFragment = ""
    }

    func update(query newQuery: String) {
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed
        guard !trimmed.isEmpty else {
            clearResults()
            return
        }
        if isForcedWorldwide {
            worldwidePrefix = trimmed
            worldwide.queryFragment = trimmed
        } else if let prefix = worldwidePrefix, trimmed.hasPrefix(prefix) {
            worldwide.queryFragment = trimmed
        } else {
            worldwidePrefix = nil
            didFallBackToWorldwide = false
            anchored.queryFragment = trimmed
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let incoming = completer.results
        // Identity only — the completer object itself is main-actor state and must
        // not be touched from here.
        let id = ObjectIdentifier(completer)
        Task { @MainActor in self.ingest(incoming, from: id) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        let id = ObjectIdentifier(completer)
        // A failure is treated as "no results", which routes it through the same
        // worldwide retry: a network blip near the anchor shouldn't dead-end.
        Task { @MainActor in self.ingest([], from: id) }
    }

    private func ingest(_ incoming: [MKLocalSearchCompletion], from id: ObjectIdentifier) {
        let isWorldwide = (id == ObjectIdentifier(worldwide))
        // Exactly one of the two completers is "live" at a time; a late reply from
        // the other belongs to a question we have already stopped asking.
        guard isWorldwide == (worldwidePrefix != nil) else { return }

        if !isWorldwide {
            // Remember the anchor's answer so switching back from worldwide can
            // replay it instead of betting on a re-query.
            anchoredFragment = query
            anchoredResults = incoming
        }

        if !isWorldwide, incoming.isEmpty, !query.isEmpty, anchor != nil {
            // The anchored search has no answer here. Ask the world instead of
            // handing back a blank dropdown with no explanation.
            startWorldwideRetry()
            return
        }

        results = incoming
        didFallBackToWorldwide = isWorldwide
    }

    /// Hand the current text to the unanchored completer and mark it as the live one.
    private func startWorldwideRetry() {
        worldwidePrefix = query
        results = []
        worldwide.queryFragment = query
    }
}

struct AddressSearchBar: View {
    var placeholder: String = "Search address or place"
    /// Reference point used to recover *short* Plus Codes (e.g. "9G8F+6X").
    /// Full Plus Codes and plain coordinates don't need it. Typically the
    /// current map center.
    var mapCenter: CLLocationCoordinate2D? = nil
    /// Where autocomplete and place lookup should be centred — normally the current
    /// spoof target or pin. `nil` keeps MapKit's untouched (device-biased) behaviour,
    /// which is correct for hosts that have no target yet.
    var searchAnchor: MapSearchAnchor? = nil
    /// The device's REAL coordinate, if the host already has one. Only used to offer
    /// "search near me instead" — never as the default anchor.
    ///
    /// CONTRACT: this must be a coordinate captured BEFORE any simulation started.
    /// While a spoof is live, CoreLocation reports the FAKE position to this app too
    /// (that is precisely what the "Check my spoof" card relies on), so a freshly
    /// fetched device coordinate would be the spoof target wearing a "your real
    /// location" label — a lie in the one feature whose whole job is map honesty.
    /// Hosts that cannot guarantee a pre-simulation snapshot must pass `nil`, which
    /// hides the toggle entirely.
    var realLocation: CLLocationCoordinate2D? = nil
    var onPick: (CLLocationCoordinate2D, String) -> Void
    /// Fires true while the field is focused OR showing results, so a host can get out of the way
    /// (e.g. hide a floating top card that would otherwise cover the results list).
    var onActiveChange: ((Bool) -> Void)? = nil

    @StateObject private var completer = AnchoredPlaceCompleter()
    @ObservedObject private var anchorNames = SearchAnchorNames.shared
    /// True once the user has explicitly asked for results near their real location
    /// instead of the spoof target. Resets when the anchor itself changes, so a new
    /// teleport doesn't inherit a stale "near me".
    @State private var preferRealLocation = false
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

    /// The anchor actually handed to MapKit: the host's target unless the user has
    /// asked for their real location AND the host gave us one to use.
    private var effectiveAnchor: MapSearchAnchor? {
        guard let searchAnchor else { return nil }
        guard preferRealLocation, let realLocation else {
            // Upgrade the host's honest role name ("your pin") to a real place name
            // once one has been geocoded for this cell. Until then the role name
            // stands — it is never wrong, only vaguer.
            guard let resolved = anchorNames.name(for: searchAnchor.coordinate) else { return searchAnchor }
            return MapSearchAnchor(
                coordinate: searchAnchor.coordinate,
                name: resolved,
                radiusMeters: searchAnchor.radiusMeters,
                isRealLocation: searchAnchor.isRealLocation
            )
        }
        return MapSearchAnchor(
            coordinate: realLocation,
            name: anchorNames.name(for: realLocation)
                ?? L("search.anchor.real", fallback: "your real location"),
            radiusMeters: searchAnchor.radiusMeters,
            isRealLocation: true
        )
    }

    /// The text actually being searched, trimmed.
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the results panel should be on screen at all.
    ///
    /// Crucially this is NOT "are there results". An anchored search that returns
    /// nothing is the moment the user most needs to be told where we were looking
    /// and offered somewhere else to look — a blank dropdown explains neither. The
    /// panel therefore also opens on an empty result set, as long as there is an
    /// anchor to explain and text to explain it about. Skipped when the text parses
    /// as a coordinate, because the "Go to …" row above has already answered.
    private var showsResultsPanel: Bool {
        if !completer.results.isEmpty { return true }
        return effectiveAnchor != nil && !trimmedQuery.isEmpty && parsedTarget == nil
    }

    /// Small, honest header above the results list: which place these results are
    /// ranked around, plus the one-tap way to rank them around somewhere else.
    /// Shown only when there is something to explain — an anchored search — so the
    /// five hosts that pass no anchor look exactly as they did before.
    /// Which of the three searches produced the list on screen, said plainly.
    /// Quietly widening the region — or quietly keeping it — would leave the user
    /// reading Tokyo-ranked results under a Paris pin with no idea why.
    private func anchorSentence(_ anchor: MapSearchAnchor) -> String {
        if completer.isForcedWorldwide {
            return L("search.results_anywhere", fallback: "Results from anywhere")
        }
        if completer.didFallBackToWorldwide {
            return String(format: L("search.nothing_near",
                                    fallback: "Nothing near %@ — showing results worldwide"),
                          anchor.name)
        }
        return String(format: L("search.results_near", fallback: "Results near %@"), anchor.name)
    }

    @ViewBuilder
    private var anchorHeader: some View {
        if let anchor = effectiveAnchor {
            HStack(spacing: 6) {
                // Icon + sentence read as ONE VoiceOver element; the escape-hatch
                // buttons stay separate, focusable ones. Combining the whole row
                // would bury the only controls that change where we're searching.
                HStack(spacing: 6) {
                    Image(systemName: (completer.isForcedWorldwide || completer.didFallBackToWorldwide)
                          ? "globe"
                          : (anchor.isRealLocation ? "location.fill" : "mappin.and.ellipse"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(anchorSentence(anchor))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 4)

                if completer.isForcedWorldwide {
                    // Only one control while unanchored: come back. "Near me" would be
                    // offering to swap between two anchors when none is in use.
                    scopeButton(L("search.scope.nearby", fallback: "Nearby")) {
                        completer.setForceWorldwide(false)
                    }
                } else {
                    // Hidden once the automatic retry has already gone worldwide —
                    // the button would do nothing the list hasn't done for itself.
                    if !completer.didFallBackToWorldwide {
                        scopeButton(L("search.scope.anywhere", fallback: "Anywhere")) {
                            completer.setForceWorldwide(true)
                        }
                    }
                    if realLocation != nil {
                        scopeButton(anchor.isRealLocation
                                    ? L("search.near_target", fallback: "Near my pin")
                                    : L("search.near_me", fallback: "Near me")) {
                            preferRealLocation.toggle()
                            // Name whichever side we just switched TO, so the header can
                            // stop saying "your real location" once a locality is known.
                            if preferRealLocation, let realLocation {
                                SearchAnchorNames.shared.resolve(realLocation)
                            } else if let searchAnchor {
                                SearchAnchorNames.shared.resolve(searchAnchor.coordinate)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
    }

    private func scopeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Wander.brand)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(placeholder, text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.search)
                    .onChange(of: query) { _, newValue in completer.update(query: newValue) }
                if !query.isEmpty {
                    Button {
                        query = ""
                        completer.clearResults()
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

            if showsResultsPanel {
                VStack(spacing: 0) {
                    anchorHeader
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
                    // Only once BOTH searches have come back empty — never during the
                    // gap between keystroke and reply, where a flashing "no matches"
                    // would be wrong more often than right.
                    if completer.results.isEmpty, completer.didFallBackToWorldwide {
                        Text(L("search.no_matches", fallback: "No matching places."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, completer.results.isEmpty ? 4 : 0)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        // Keep the completer pointed at the current anchor. `.task(id:)` re-runs when
        // the anchor's coarse identity changes (a teleport, a "near me" flip), not on
        // every pan — see `MapSearchAnchor.regionKey`.
        .task(id: effectiveAnchor?.regionKey) {
            completer.setAnchor(effectiveAnchor)
        }
        // A new target means the previous "near me" choice was about a different trip.
        .onChange(of: searchAnchor?.regionKey) { _, _ in
            preferRealLocation = false
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                probeClipboard()
                // Only now is it worth spending a geocode: the user is actually
                // searching, so a real place name in the header earns its cost.
                if let searchAnchor { SearchAnchorNames.shared.resolve(searchAnchor.coordinate) }
                if preferRealLocation, let realLocation { SearchAnchorNames.shared.resolve(realLocation) }
            }
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

    /// Active = the user is searching: focused, or there is a panel / parsed target
    /// on screen. Uses `showsResultsPanel` rather than "are there results", so the
    /// explain-only panel (anchor header with an empty list) also gets clear air
    /// instead of being slid under the floating info card.
    private func reportActive() {
        onActiveChange?(focused || showsResultsPanel || parsedTarget != nil)
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
        completer.clearResults()
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
        // No region at all when the list came from the worldwide retry: the tapped
        // place is by definition NOT near the anchor, and biasing the lookup back
        // toward it is how "Eiffel Tower" resolves to a bistro in Tokyo.
        if let anchor = effectiveAnchor,
           !completer.didFallBackToWorldwide, !completer.isForcedWorldwide {
            request.region = anchor.region
            // `.default`, NOT `.required`, on purpose. The completion the user tapped
            // was already ranked inside this region, so the region's job here is only
            // to disambiguate identical names ("Springfield"). Making it required
            // would let a result that sits just outside the box resolve to nothing —
            // a tap that does nothing at all, which is worse than a slightly-off pin.
            if #available(iOS 18.0, *) { request.regionPriority = .default }
        }
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            let coordinate = item.placemark.coordinate
            Task { @MainActor in onPick(coordinate, completion.title) }
        }
        query = ""
        completer.clearResults()
        focused = false
    }
}
