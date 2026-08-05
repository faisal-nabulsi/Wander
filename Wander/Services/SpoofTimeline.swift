//
//  SpoofTimeline.swift
//  Wander
//
//  A record of where the user PRETENDED to be.
//
//  Until now Wander was a remote control that forgets: it writes a coordinate into the device and
//  keeps nothing, so nobody can check whether the story their location tells actually holds together.
//  "Was I plausibly at home all evening?" / "Did last night's route look like a person or like a
//  teleport?" were unanswerable, by the one piece of software that knew the answer.
//
//  This file is the ledger half of the answer. TimelineView is the reading half.
//
//  ── WHAT IT IS NOT ───────────────────────────────────────────────────────────────────────────────
//  It is NOT tracking. Every coordinate in here was written BY WANDER, into the device, at the user's
//  instruction. Nothing about the real device location is ever recorded (the one exception is tagged
//  `.priming` and is discussed below). Nothing here is uploaded, synced, or backed up by any Wander
//  service — see `wipeEverything()`, which really does delete the bytes.
//
//  ── SHAPE (modelled on CooldownJournal, the app's only other persisted timestamped ledger) ───────
//   * Codable-with-defaults discipline: every field added after v1 MUST decode when the key is
//     absent. Swift's SYNTHESISED decoder does not do that — a `var x: Int = 0` still throws
//     `keyNotFound`, which for a ledger means an upgrade silently eats the user's whole history — so
//     the decoders here are written by hand with `decodeIfPresent`. (CooldownJournal documents the
//     same rule but relies on synthesis; see the note at the bottom of this file.)
//   * A dual cap, both applied, whichever bites first: an age cap (`retentionDays`) and a per-day
//     entry cap (`maxFixesPerDay`).
//   * Everything lives under one root directory so "delete it all" is one recursive remove.
//
//  ── LAYOUT ──────────────────────────────────────────────────────────────────────────────────────
//    Application Support/wander-spoof-timeline/
//      index.json                  — one small row per day (count, first/last, bytes)
//      labels.json                 — reverse-geocoded dwell labels, cached so we ask Apple once
//      days/2026-08-04.jsonl       — one JSON object per line, append-only, oldest line first
//
//  THE `days/` DIRECTORY IS THE RECORD; `index.json` is only a debounced cache of its summaries. The
//  reader therefore reconciles against the directory once per launch (`reconcileWithDisk`) and the
//  retention sweep deletes by FILE, so a file whose index row never got flushed is still listed, still
//  rendered, and still expires on schedule instead of sitting on disk unseen and undeletable.
//
//  JSON-lines rather than one array-per-day because the write path is an APPEND: a live walk emits a
//  fix every couple of seconds, and re-encoding a growing array on each one would be quadratic. A
//  line is written with one `write(contentsOf:)` on a cached handle, which is a syscall, not a
//  serialisation pass.
//
//  ── THE WRITE PATH IS SACRED ────────────────────────────────────────────────────────────────────
//  `SpoofTimelineRecorder.record` is called from the serial location command queue, immediately after
//  the FFI inject returns. It therefore does the absolute minimum on that queue: validate two doubles,
//  take a timestamp, and `async` onto its own utility queue. No locks the caller can contend on, no
//  file I/O, no UserDefaults read, no allocation that outlives the hop. If literally everything in
//  here fails, the spoof is unaffected — nothing on the inject path ever reads a result from this
//  file.
//

import Foundation
import CoreLocation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Geometry (cheap, dependency-free)

/// Distance maths kept local and allocation-free.
///
/// Not `CLLocation.distance(from:)`: the coalescer runs it on every single inject, and that call
/// allocates two Objective-C objects to answer a question that is, at these ranges, four multiplies.
///
/// Equirectangular projection is exact enough for everything it's asked here — sub-centimetre over
/// the tens of metres the coalescer and the dwell detector work at, and a fraction of a percent over
/// a day of ordinary travel. It drifts to a couple of percent on an intercontinental teleport
/// (measured: Tokyo→Honolulu reads 6,300 km against a true 6,200 km), which is fine for a "distance
/// covered" figure and is NOT fine for navigation. Nothing navigates from this.
enum SpoofGeo {
    static let earthRadius: Double = 6_371_000

    static func meters(_ aLat: Double, _ aLng: Double, _ bLat: Double, _ bLng: Double) -> Double {
        let latRad = (aLat + bLat) * 0.5 * .pi / 180
        let dLat = (bLat - aLat) * .pi / 180
        // Wrapped to ±180 before projecting. Without this, a teleport from Tokyo to Honolulu reads as
        // a 359° longitude delta — a ~39,000 km "move" across a map the user can see is a short hop.
        // A spoofer crosses the anti-meridian far more often than a fitness app does.
        var deltaLng = bLng - aLng
        if deltaLng > 180 { deltaLng -= 360 } else if deltaLng < -180 { deltaLng += 360 }
        let dLng = deltaLng * .pi / 180 * cos(latRad)
        return earthRadius * (dLat * dLat + dLng * dLng).squareRoot()
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        meters(a.latitude, a.longitude, b.latitude, b.longitude)
    }
}

// MARK: - What wrote this fix

/// Which part of the app produced a coordinate.
///
/// This exists mostly for ONE row of it. `RealGPSSeeder` pushes the device's genuine GPS position as
/// an opening fix (the "first fix is real" guardrail), and those pushes are not places the user went
/// — they're plumbing. Rendered undifferentiated, a session started at home at 2 a.m. and a target in
/// another country reads as a 2 a.m. road trip that never happened. `.priming` rows are stored (they
/// are part of the honest record of what Wander wrote) and excluded from every segment, distance and
/// path by default.
///
/// Raw values are the persisted form and must never change. An unknown value decodes to `.other`
/// rather than throwing, so a downgrade to an older build can still read a newer build's file.
enum SpoofFixSource: String, Codable, CaseIterable, Hashable {
    /// A point the user placed: map teleport, saved place, search result.
    case teleport
    /// Joystick / walk mode.
    case walk
    /// Following a route.
    case route
    /// The itinerary runner stepping to its next stop.
    case itinerary
    /// A scheduled jump firing.
    case schedule
    /// Shortcuts / App Intents.
    case shortcut
    /// `RealGPSSeeder` — the device's REAL position, injected as an opening fix. Never a destination.
    case priming
    /// The gs-loc (anti-cheat) path rather than the developer tunnel.
    case gsloc
    /// Anything not yet routed through a named source.
    case other

    var title: String {
        switch self {
        case .teleport:  return L("timeline.src.teleport", fallback: "Teleport")
        case .walk:      return L("timeline.src.walk", fallback: "Walk")
        case .route:     return L("timeline.src.route", fallback: "Route")
        case .itinerary: return L("timeline.src.itinerary", fallback: "Itinerary")
        case .schedule:  return L("timeline.src.schedule", fallback: "Schedule")
        case .shortcut:  return L("timeline.src.shortcut", fallback: "Shortcut")
        case .priming:   return L("timeline.src.priming", fallback: "Real-GPS priming")
        case .gsloc:     return L("timeline.src.gsloc", fallback: "PoGo mode")
        case .other:     return L("timeline.src.other", fallback: "Spoof")
        }
    }

    var symbol: String {
        switch self {
        case .teleport:  return "mappin.and.ellipse"
        case .walk:      return "figure.walk"
        case .route:     return "point.topleft.down.to.point.bottomright.curvepath"
        case .itinerary: return "list.bullet.rectangle"
        case .schedule:  return "clock.badge.checkmark"
        case .shortcut:  return "app.connected.to.app.below.fill"
        case .priming:   return "antenna.radiowaves.left.and.right"
        case .gsloc:     return "wifi"
        case .other:     return "location.fill"
        }
    }

    /// Whether this row describes somewhere the user's location CLAIMED to be. False for `.priming`,
    /// which is the device's real position and belongs to no story.
    var isPartOfStory: Bool { self != .priming }

    init(persisted raw: String?) {
        self = SpoofFixSource(rawValue: raw ?? "") ?? .other
    }
}

// MARK: - One recorded fix

/// A single coordinate Wander wrote into the device, and when.
///
/// Keys are one or two characters because this is the line format of an append-only file that a
/// heavy day writes a few thousand of; the field names cost more bytes than the values do. The
/// timestamp is seconds-since-1970 as a Double for the same reason (and because it sorts, unlike
/// ISO-8601 across locales).
///
/// EVERY field except `t`/`lat`/`lng` decodes with a default. That is not politeness — an existing
/// user's history is on disk in the previous shape, and a decoder that throws on a missing key
/// deletes their record on upgrade.
struct SpoofFix: Codable, Identifiable, Equatable {
    /// When Wander wrote it.
    var t: Date
    var lat: Double
    var lng: Double
    /// What part of the app asked for it. Added v1; still decoded defensively.
    var src: SpoofFixSource = .other
    /// Whether the inject reported success. A rejected write is still worth keeping: a run of them is
    /// exactly the "my spoof looked live but wasn't" story the timeline is here to expose.
    var ok: Bool = true

    var id: Double { t.timeIntervalSince1970 }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    init(t: Date, lat: Double, lng: Double, src: SpoofFixSource, ok: Bool) {
        self.t = t
        self.lat = lat
        self.lng = lng
        self.src = src
        self.ok = ok
    }

    private enum CodingKeys: String, CodingKey {
        case t, lat, lng, src, ok
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The three fields a row is meaningless without. A line missing any of them is corrupt, and
        // the reader drops that ONE line rather than the file.
        t = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .t))
        lat = try c.decode(Double.self, forKey: .lat)
        lng = try c.decode(Double.self, forKey: .lng)
        src = SpoofFixSource(persisted: try c.decodeIfPresent(String.self, forKey: .src))
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t.timeIntervalSince1970, forKey: .t)
        try c.encode(lat, forKey: .lat)
        try c.encode(lng, forKey: .lng)
        try c.encode(src.rawValue, forKey: .src)
        try c.encode(ok, forKey: .ok)
    }
}

// MARK: - Day index

/// The cheap summary of a day, so the scrubber can be built without opening a single .jsonl.
///
/// Same defaulting rule as `SpoofFix`: a missing key must never cost the user their index (which
/// would orphan every day file behind it).
struct SpoofTimelineDay: Codable, Identifiable, Equatable {
    /// "YYYY-MM-DD" in the user's own calendar. Also the file name.
    var day: String
    var fixCount: Int = 0
    var first: Date?
    var last: Date?
    /// Fixes that are part of the story (i.e. excluding `.priming`), so a day made entirely of
    /// priming pushes can be shown as the nothing it is.
    var storyFixCount: Int = 0

    var id: String { day }

    init(day: String, fixCount: Int = 0, first: Date? = nil, last: Date? = nil, storyFixCount: Int = 0) {
        self.day = day
        self.fixCount = fixCount
        self.first = first
        self.last = last
        self.storyFixCount = storyFixCount
    }

    private enum CodingKeys: String, CodingKey {
        case day, fixCount, first, last, storyFixCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        fixCount = try c.decodeIfPresent(Int.self, forKey: .fixCount) ?? 0
        first = try c.decodeIfPresent(Date.self, forKey: .first)
        last = try c.decodeIfPresent(Date.self, forKey: .last)
        // Older files predate the priming split; assuming every fix was part of the story is the
        // right way to be wrong, since it only over-counts a number shown as a footnote.
        storyFixCount = try c.decodeIfPresent(Int.self, forKey: .storyFixCount) ?? fixCount
    }

    /// Midnight-anchored `Date` for this day key, in the calendar that wrote it. nil for a malformed
    /// key (hand-edited file, a format that never existed).
    var date: Date? { SpoofTimelineFiles.date(fromDayKey: day) }
}

// MARK: - Files

/// Everything that knows a path. Kept apart from the recorder so the wipe, the reader and the writer
/// can't drift onto three different ideas of where the data lives.
enum SpoofTimelineFiles {
    static let directoryName = "wander-spoof-timeline"

    static var root: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    static var daysDirectory: URL { root.appendingPathComponent("days", isDirectory: true) }
    static var indexURL: URL { root.appendingPathComponent("index.json", isDirectory: false) }
    static var labelsURL: URL { root.appendingPathComponent("labels.json", isDirectory: false) }

    static func dayURL(_ day: String) -> URL {
        daysDirectory.appendingPathComponent("\(day).jsonl", isDirectory: false)
    }

    @discardableResult
    static func ensureDirectories() -> Bool {
        (try? FileManager.default.createDirectory(at: daysDirectory,
                                                  withIntermediateDirectories: true,
                                                  attributes: nil)) != nil
    }

    // Day keys are formatted in the user's CURRENT calendar and time zone, deliberately: "yesterday"
    // means the user's yesterday, not UTC's. The formatter is cached because it is built on the write
    // path, and rebuilt when the zone changes so a flight doesn't leave the ledger a day behind.
    //
    // LOCK-GUARDED, and it has to be: `dayKey` is called from the recorder's utility queue on every
    // written fix AND from the main thread by the day scrubber. `DateFormatter` is documented as
    // thread-safe only for FORMATTING — building one on one thread while another formats through the
    // same reference is not, and neither is the cache swap itself. The lock is never taken on the
    // serial location command queue (nothing on the inject path calls this), so it can't add latency
    // where latency matters.
    private static let formatterLock = NSLock()
    private static var cachedFormatter: DateFormatter?
    private static var cachedZone: TimeZone?

    private static func formatter() -> DateFormatter {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let zone = TimeZone.current
        if let cachedFormatter, cachedZone == zone { return cachedFormatter }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        cachedFormatter = f
        cachedZone = zone
        return f
    }

    static func dayKey(for date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(fromDayKey key: String) -> Date? {
        formatter().date(from: key)
    }

    /// Whether a string is shaped like a day key ("2026-08-04"). Used when adopting files found on
    /// disk, so a stray `.jsonl` someone dropped into the folder can't become a phantom day.
    ///
    /// Checked by SHAPE rather than by parsing, deliberately: `date(fromDayKey:)` uses the CURRENT
    /// time zone, and a file written in another zone is still a real file of the user's fixes.
    static func isDayKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Every day key that has a file on disk, newest-key-last. nil (not empty!) when the directory
    /// can't be listed, so callers can tell "no files" from "couldn't look" and never delete or
    /// forget rows on the strength of a failed enumeration.
    static func dayKeysOnDisk() -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: daysDirectory.path)
        else { return nil }
        return names.compactMap { name in
            guard name.hasSuffix(".jsonl") else { return nil }
            let key = String(name.dropLast(6))
            return isDayKey(key) ? key : nil
        }.sorted()
    }
}

// MARK: - The writer

/// The only thing on the inject path. Everything here except `record` runs on `queue`.
///
/// ⚠️ CONTRACT: `record` is invoked from the serial location command queue, one line after the FFI
/// write. It may not block, may not throw, may not allocate anything that outlives the dispatch, and
/// may not fail in a way the caller can observe. It returns void on purpose — there is no result for
/// a caller to branch on, so no caller can ever come to depend on the ledger working.
enum SpoofTimelineRecorder {

    // MARK: Tuning

    /// Coalescing. A joystick walk injects several times a second and a route hold re-asserts the
    /// same point every few seconds; writing all of it would be megabytes of duplicate coordinate for
    /// a picture that is identical at a tenth the size. One fix per ~10 m or ~15 s reconstructs a
    /// path indistinguishably at any zoom the map offers.
    static let minMetersBetweenFixes: Double = 10
    static let minSecondsBetweenFixes: TimeInterval = 15

    /// Dual cap, exactly as CooldownJournal does it — whichever bites first.
    ///
    /// The count cap is per DAY (a day is the unit the reader scrubs through, so it's the unit worth
    /// bounding). 4,000 coalesced fixes is roughly 16 continuous hours of walking; past that the
    /// oldest lines of that day are dropped, never the newest, so the cap never hides what just
    /// happened. Compaction is deferred to `compactionSlack` past the cap so a long walk isn't
    /// rewriting its file on every fix at the boundary.
    static let maxFixesPerDay = 4_000
    static let compactionSlack = 500
    static let retentionDays = 30

    /// Legs longer than this are a jump-cut, not travel: excluded from peak speed and from dwell
    /// detection, because a stationary phone that was simply closed for an hour is not a dwell we
    /// observed.
    static let gapSeconds: TimeInterval = 20 * 60

    /// Master switch. Off means nothing is written at all (existing files stay until wiped).
    static let enabledKey = "spoofTimelineEnabled"

    /// Posted after the ledger changes on disk. Coalesced by the writer — at most one per flush — so
    /// a live walk doesn't wake the UI 4,000 times.
    static let didChangeNotification = Notification.Name("wander.spoofTimeline.didChange")

    // MARK: Queue

    /// Private, serial, utility. Serial is what makes the state below safe without a lock, and what
    /// makes "wipe" honest: a wipe enqueued after an append cannot be overtaken by it.
    static let queue = DispatchQueue(label: "com.wander.spoof-timeline", qos: .utility)

    // Every var below is touched ONLY on `queue`.
    private static var lastWritten: SpoofFix?
    private static var index: [String: SpoofTimelineDay] = [:]
    private static var indexLoaded = false
    private static var indexDirty = false
    private static var indexWriteScheduled = false
    private static var handle: FileHandle?
    private static var handleDay: String?
    private static var prunedThisLaunch = false
    private static var appendsSinceCompactionCheck = 0

    // MARK: The one entry point

    /// Note that Wander wrote a coordinate into the device.
    ///
    /// PURE FIRE-AND-FORGET. Two float checks, a timestamp, a dispatch. Nothing else happens on the
    /// caller's queue — not a lock, not a UserDefaults read, not a `Calendar` lookup.
    static func record(latitude: Double,
                       longitude: Double,
                       source: SpoofFixSource,
                       accepted: Bool) {
        // A NaN would poison every distance downstream and render as a broken map, so it is dropped
        // at the door. Cheap enough to belong on the calling queue.
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180 else { return }
        let now = Date()
        queue.async {
            ingest(SpoofFix(t: now, lat: latitude, lng: longitude, src: source, ok: accepted))
        }
    }

    /// Push anything buffered to disk now. Safe to call from anywhere; returns immediately.
    /// (Fix lines are written straight through, so this only settles the index.)
    static func flush() {
        queue.async { writeIndexIfDirty() }
    }

    // MARK: Ingest (queue only)

    private static var isEnabled: Bool {
        // Default TRUE, so this reads `object(forKey:) == nil ? true : bool(forKey:)`.
        guard let value = UserDefaults.standard.object(forKey: enabledKey) as? Bool else { return true }
        return value
    }

    private static func ingest(_ fix: SpoofFix) {
        guard isEnabled else { return }
        loadIndexIfNeeded()
        pruneOldDaysOnce()

        guard shouldWrite(fix) else { return }
        guard let line = encode(fix) else { return }

        let day = SpoofTimelineFiles.dayKey(for: fix.t)
        guard append(line, to: day) else { return }

        lastWritten = fix

        var row = index[day] ?? SpoofTimelineDay(day: day)
        row.fixCount += 1
        if fix.src.isPartOfStory { row.storyFixCount += 1 }
        if row.first == nil || fix.t < (row.first ?? fix.t) { row.first = fix.t }
        row.last = fix.t
        index[day] = row
        indexDirty = true
        scheduleIndexWrite()

        appendsSinceCompactionCheck += 1
        if appendsSinceCompactionCheck >= 50 {
            appendsSinceCompactionCheck = 0
            compactIfNeeded(day)
        }
    }

    /// The coalescer. Deliberately generous about writing: a change of source or of success is worth
    /// a row even at zero distance, because "the walk ended and a teleport began here" and "this is
    /// where the injects started failing" are both things the reader is looking for.
    private static func shouldWrite(_ fix: SpoofFix) -> Bool {
        guard let last = lastWritten else { return true }
        if fix.src != last.src { return true }
        if fix.ok != last.ok { return true }
        let dt = fix.t.timeIntervalSince(last.t)
        // A clock that went backwards (NTP correction, manual change) must not stall the ledger
        // forever, so a negative delta counts as "write it".
        if dt < 0 || dt >= minSecondsBetweenFixes { return true }
        if SpoofTimeline.dayKeyDiffers(fix.t, last.t) { return true }
        return SpoofGeo.meters(last.lat, last.lng, fix.lat, fix.lng) >= minMetersBetweenFixes
    }

    private static func encode(_ fix: SpoofFix) -> Data? {
        guard var data = try? JSONEncoder().encode(fix) else { return nil }
        // The line format's one invariant. JSONEncoder never emits a newline for this struct (no
        // strings, not pretty-printed), but the reader splits on \n and a single stray byte would
        // corrupt every line after it — so it is checked, not assumed.
        if data.contains(0x0A) { return nil }
        data.append(0x0A)
        return data
    }

    // MARK: Files (queue only)

    /// Append one line, keeping the day's handle open between calls. Returns false if nothing landed,
    /// in which case the caller must not count the fix.
    private static func append(_ line: Data, to day: String) -> Bool {
        if handleDay != day { closeHandle() }
        if handle == nil {
            SpoofTimelineFiles.ensureDirectories()
            let url = SpoofTimelineFiles.dayURL(day)
            if !FileManager.default.fileExists(atPath: url.path) {
                // Created explicitly so we can pin the protection class: the ledger is written from a
                // background hold loop, which can run with the device LOCKED, and the stricter
                // `.complete` class would fail every one of those writes.
                FileManager.default.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
                )
            }
            handle = try? FileHandle(forWritingTo: url)
            guard let handle else { handleDay = nil; return false }
            guard (try? handle.seekToEnd()) != nil else { closeHandle(); return false }
            handleDay = day
        }
        guard let handle else { return false }
        do {
            try handle.write(contentsOf: line)
            return true
        } catch {
            // A failed write is not worth a retry loop on a background queue — drop the handle so the
            // next fix rebuilds it, and lose exactly one row.
            closeHandle()
            return false
        }
    }

    private static func closeHandle() {
        try? handle?.close()
        handle = nil
        handleDay = nil
    }

    // MARK: Index (queue only)

    private static func loadIndexIfNeeded() {
        guard !indexLoaded else { return }
        indexLoaded = true
        if let data = try? Data(contentsOf: SpoofTimelineFiles.indexURL),
           let rows = try? JSONDecoder().decode([SpoofTimelineDay].self, from: data) {
            for row in rows { index[row.day] = row }
        }
        reconcileWithDisk()
    }

    /// Make the index agree with what is actually in `days/`.
    ///
    /// THE INDEX IS NOT THE RECORD — the `.jsonl` files are. The index is a debounced cache of their
    /// summaries (`scheduleIndexWrite` waits 5 s, with a background-notification flush), so there is a
    /// real window in which a day file holds real coordinates and no index row describes it. A jetsam,
    /// a force-quit or a failed atomic write inside that window used to leave that file PERMANENTLY
    /// invisible — never listed by the scrubber (`loadIndex` reads `index.values`) and, worse, never
    /// deleted by the 30-day sweep (`pruneOldDaysOnce` walked `index.keys`), which quietly made a lie
    /// of the privacy footer's promise that history is "kept for up to 30 days".
    ///
    /// So the directory is the source of truth, once per launch:
    ///   * a file with no row is ADOPTED, its summary recounted from the lines that are really there;
    ///   * a row with no file is DROPPED, because the bytes it describes are already gone.
    ///
    /// Both halves are skipped entirely when the directory can't be listed — a failed enumeration
    /// must never be read as "there are no files".
    ///
    /// It DELETES NOTHING. A file that yields no decodable line is left alone rather than removed: a
    /// reader is the wrong place to throw away the user's record on the strength of a parse, and the
    /// retention sweep now works off file names, so such a file still expires on schedule instead of
    /// living forever. Reconciling only ever edits the cache.
    ///
    /// Safe against the writer because both run on the same serial queue AND this runs from
    /// `loadIndexIfNeeded`, which every `ingest` calls before it creates or appends to anything — so
    /// a file being written this launch is never seen mid-creation.
    private static func reconcileWithDisk() {
        guard let onDisk = SpoofTimelineFiles.dayKeysOnDisk() else { return }
        let known = Set(onDisk)

        for day in onDisk where index[day] == nil {
            guard let data = try? Data(contentsOf: SpoofTimelineFiles.dayURL(day)) else { continue }
            let fixes = decodeLines(data)
            guard !fixes.isEmpty else { continue }
            var row = SpoofTimelineDay(day: day)
            row.fixCount = fixes.count
            row.storyFixCount = fixes.reduce(0) { $0 + ($1.src.isPartOfStory ? 1 : 0) }
            row.first = fixes.first?.t
            row.last = fixes.last?.t
            index[day] = row
            indexDirty = true
        }

        // Snapshotted before mutating, so the removal loop can't read a collection it is editing.
        for day in Array(index.keys) where !known.contains(day) {
            index[day] = nil
            indexDirty = true
        }
    }

    /// Debounced: a live walk changes the index on every fix, and re-encoding 30 rows each time would
    /// be the one genuinely wasteful thing in this file.
    private static func scheduleIndexWrite() {
        guard !indexWriteScheduled else { return }
        indexWriteScheduled = true
        queue.asyncAfter(deadline: .now() + 5) {
            indexWriteScheduled = false
            writeIndexIfDirty()
        }
    }

    private static func writeIndexIfDirty() {
        guard indexDirty else { return }
        indexDirty = false
        writeIndex()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    private static func writeIndex() {
        SpoofTimelineFiles.ensureDirectories()
        let rows = index.values.sorted { $0.day > $1.day }
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: SpoofTimelineFiles.indexURL, options: .atomic)
    }

    // MARK: Caps (queue only)

    /// Age cap. Run once per launch — the day boundary can only move while the app is alive if the
    /// user leaves it open past midnight, and one extra day of retention is not worth a `stat` on
    /// every fix.
    private static func pruneOldDaysOnce() {
        guard !prunedThisLaunch else { return }
        prunedThisLaunch = true
        let cutoff = SpoofTimelineFiles.dayKey(
            for: Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        )
        // Driven by the FILES, unioned with the index — not by the index alone. The index is a cache
        // that can lag or be lost (see `reconcileWithDisk`), and a sweep that only walked its keys
        // would step straight over an orphaned day file and leave real coordinates on disk forever,
        // which is precisely what the retention promise in the privacy footer says cannot happen.
        //
        // String comparison is a correct date comparison for zero-padded ISO day keys, and doesn't
        // need a calendar.
        var candidates = Set(index.keys)
        if let onDisk = SpoofTimelineFiles.dayKeysOnDisk() { candidates.formUnion(onDisk) }
        let expired = candidates.filter { $0 < cutoff }
        guard !expired.isEmpty else { return }
        for day in expired {
            if handleDay == day { closeHandle() }
            try? FileManager.default.removeItem(at: SpoofTimelineFiles.dayURL(day))
            index[day] = nil
        }
        indexDirty = true
        writeIndexIfDirty()
    }

    /// Count cap. Rewrites the day keeping the NEWEST `maxFixesPerDay` lines — the same direction
    /// CooldownJournal prunes in, for the same reason: a cap that dropped the newest entries would
    /// hide the thing the user just did.
    private static func compactIfNeeded(_ day: String) {
        guard let row = index[day], row.fixCount > maxFixesPerDay + compactionSlack else { return }
        let url = SpoofTimelineFiles.dayURL(day)
        guard let data = try? Data(contentsOf: url) else { return }

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > maxFixesPerDay else { return }
        lines = Array(lines.suffix(maxFixesPerDay))

        var rebuilt = Data()
        rebuilt.reserveCapacity(data.count)
        for line in lines {
            rebuilt.append(contentsOf: line)
            rebuilt.append(0x0A)
        }
        // The open handle points into the file we're about to replace, so it must go first.
        closeHandle()
        guard (try? rebuilt.write(to: url, options: .atomic)) != nil else { return }

        // Recount from what actually survived rather than trusting arithmetic on a file we just
        // rewrote; the index is what the whole UI reads.
        let survivors = decodeLines(rebuilt)
        var updated = SpoofTimelineDay(day: day)
        updated.fixCount = survivors.count
        updated.storyFixCount = survivors.reduce(0) { $0 + ($1.src.isPartOfStory ? 1 : 0) }
        updated.first = survivors.first?.t
        updated.last = survivors.last?.t
        index[day] = updated
        indexDirty = true
        writeIndexIfDirty()
    }

    // MARK: Reading + deleting (queue only, called through SpoofTimeline)

    static func decodeLines(_ data: Data) -> [SpoofFix] {
        let decoder = JSONDecoder()
        var out: [SpoofFix] = []
        out.reserveCapacity(min(maxFixesPerDay, 512))
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            // One corrupt line (a half-written tail after a kill, a hand edit) loses that line and
            // nothing else. An all-or-nothing parse would throw away the day.
            if let fix = try? decoder.decode(SpoofFix.self, from: Data(line)) { out.append(fix) }
        }
        // Appends are chronological, but a clock change can produce an out-of-order tail.
        return out.sorted { $0.t < $1.t }
    }

    static func loadFixes(day: String, completion: @escaping ([SpoofFix]) -> Void) {
        queue.async {
            writeIndexIfDirty()
            guard let data = try? Data(contentsOf: SpoofTimelineFiles.dayURL(day)) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let fixes = decodeLines(data)
            DispatchQueue.main.async { completion(fixes) }
        }
    }

    static func loadIndex(completion: @escaping ([SpoofTimelineDay]) -> Void) {
        queue.async {
            loadIndexIfNeeded()
            pruneOldDaysOnce()
            let rows = index.values.filter { $0.fixCount > 0 }.sorted { $0.day > $1.day }
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Delete one day, for real.
    static func deleteDay(_ day: String, completion: @escaping () -> Void) {
        queue.async {
            loadIndexIfNeeded()
            if handleDay == day { closeHandle() }
            try? FileManager.default.removeItem(at: SpoofTimelineFiles.dayURL(day))
            index[day] = nil
            if let last = lastWritten, SpoofTimelineFiles.dayKey(for: last.t) == day { lastWritten = nil }
            indexDirty = true
            writeIndex()
            indexDirty = false
            DispatchQueue.main.async { completion() }
        }
    }

    /// Delete everything, for real: the day files, the index, the cached labels, and the directory
    /// itself. Runs on the same serial queue as the writer, so an append already in flight is either
    /// fully before this or fully after it — never interleaved, never resurrecting a deleted day.
    static func wipeEverything(completion: @escaping () -> Void) {
        queue.async {
            closeHandle()
            try? FileManager.default.removeItem(at: SpoofTimelineFiles.root)
            index.removeAll()
            indexLoaded = true      // the empty map IS the loaded state now
            indexDirty = false
            lastWritten = nil
            appendsSinceCompactionCheck = 0
            SpoofTimelineFiles.ensureDirectories()
            DispatchQueue.main.async { completion() }
        }
    }
}

// MARK: - Segments

/// A stretch of the day, rolled up: either the user's location SAT somewhere, or it MOVED.
///
/// Not persisted. It is derived from the fixes on every read, so a change to the roll-up thresholds
/// re-renders history instead of needing a migration.
struct SpoofSegment: Identifiable {
    enum Kind: String {
        /// Stayed inside `dwellRadius` for at least `dwellMinDuration`.
        case dwell
        /// Everything else.
        case move
    }

    let id: String
    let kind: Kind
    /// 1-based, dwells only — the number printed on the map pin and echoed in the list.
    let dwellNumber: Int?
    let start: Date
    let end: Date
    /// The fixes this segment was built from, in order. For a dwell this is the cluster; for a move
    /// it's the path, and it starts at the previous dwell's last point so the line has no holes.
    let coordinates: [CLLocationCoordinate2D]
    let centroid: CLLocationCoordinate2D
    let distanceMeters: Double
    let averageSpeedMps: Double
    let peakSpeedMps: Double
    let fixCount: Int
    let sources: [SpoofFixSource]
    /// True when at least one leg was a jump-cut (a teleport, or the app being away). Rendered,
    /// because an average speed across a jump-cut is not a speed anyone travelled at.
    let containsJump: Bool

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// The roll-up. A PURE FUNCTION — no I/O, no singletons, no clock, no `@MainActor`. Feed it fixes,
/// get segments; same input, same output, every time. That's what makes it testable and what lets
/// the view recompute it freely as the user scrubs days.
enum SpoofTimelineRollup {
    /// "Roughly the same place": ~80 m swallows GPS-grade wobble, a jittered hold and a walk around a
    /// building, without merging two ends of a high street.
    static let dwellRadius: Double = 80
    /// Six minutes. Short enough to catch a coffee stop, long enough that pausing at a crossing or
    /// re-centring the map doesn't manufacture a "stop".
    static let dwellMinDuration: TimeInterval = 6 * 60
    /// A leg longer than this is a jump-cut, not travel.
    static let jumpSeconds: TimeInterval = 120

    /// Roll a day's fixes into dwells and moves.
    ///
    /// - Parameter includePriming: leave false. `.priming` rows are the device's REAL position pushed
    ///   as an opening fix; folded into the path they draw a trip the user never took.
    static func segments(from fixes: [SpoofFix],
                         dwellRadius: Double = dwellRadius,
                         dwellMinDuration: TimeInterval = dwellMinDuration,
                         gapSeconds: TimeInterval = SpoofTimelineRecorder.gapSeconds,
                         includePriming: Bool = false) -> [SpoofSegment] {
        let usable = fixes
            .filter { includePriming || $0.src.isPartOfStory }
            .sorted { $0.t < $1.t }
        guard !usable.isEmpty else { return [] }

        // Split at long silences FIRST. Without this, a phone left on a table overnight and a phone
        // switched off overnight produce the same eight-hour "dwell", and only one of them is
        // something Wander actually observed.
        var runs: [[SpoofFix]] = []
        var current: [SpoofFix] = [usable[0]]
        for fix in usable.dropFirst() {
            if fix.t.timeIntervalSince(current[current.count - 1].t) > gapSeconds {
                runs.append(current)
                current = [fix]
            } else {
                current.append(fix)
            }
        }
        runs.append(current)

        var out: [SpoofSegment] = []
        for run in runs {
            out.append(contentsOf: segmentsWithinRun(run,
                                                     dwellRadius: dwellRadius,
                                                     dwellMinDuration: dwellMinDuration))
        }
        return number(out)
    }

    /// Classic anchor-based stay-point detection: park an anchor on a fix, extend while everything
    /// stays inside the radius OF THAT ANCHOR (not of a drifting centroid, which lets a slow walk
    /// creep across a city and still call itself a dwell), and accept the run as a dwell if it lasted
    /// long enough.
    private static func segmentsWithinRun(_ run: [SpoofFix],
                                          dwellRadius: Double,
                                          dwellMinDuration: TimeInterval) -> [SpoofSegment] {
        guard run.count > 1 else {
            // A lone fix in its own run is a place the user's location was, briefly, and nothing else
            // is going to represent it — so it becomes a zero-distance move rather than vanishing.
            return run.isEmpty ? [] : [makeMove(Array(run))]
        }

        var out: [SpoofSegment] = []
        var moveStart: Int?
        var i = 0

        while i < run.count {
            var j = i
            while j + 1 < run.count,
                  SpoofGeo.meters(run[i].lat, run[i].lng, run[j + 1].lat, run[j + 1].lng) <= dwellRadius {
                j += 1
            }
            let held = run[j].t.timeIntervalSince(run[i].t)
            if j > i && held >= dwellMinDuration {
                // Flush whatever movement led here. It ends ON the dwell's first fix so the drawn
                // path actually reaches the pin.
                if let s = moveStart, s < i {
                    out.append(makeMove(Array(run[s...i])))
                }
                out.append(makeDwell(Array(run[i...j])))
                // The next move begins at the dwell's LAST fix, for the same no-holes reason.
                moveStart = (j + 1 < run.count) ? j : nil
                i = j + 1
            } else {
                if moveStart == nil { moveStart = i }
                i += 1
            }
        }

        if let s = moveStart, s < run.count - 1 {
            out.append(makeMove(Array(run[s...])))
        }
        return out
    }

    private static func makeDwell(_ fixes: [SpoofFix]) -> SpoofSegment {
        let coords = fixes.map(\.coordinate)
        let centroid = mean(fixes)
        return SpoofSegment(
            id: "dwell-\(fixes[0].t.timeIntervalSince1970)",
            kind: .dwell,
            dwellNumber: nil,
            start: fixes[0].t,
            end: fixes[fixes.count - 1].t,
            coordinates: coords,
            centroid: centroid,
            distanceMeters: 0,
            averageSpeedMps: 0,
            peakSpeedMps: 0,
            fixCount: fixes.count,
            sources: uniqueSources(fixes),
            containsJump: false
        )
    }

    private static func makeMove(_ fixes: [SpoofFix]) -> SpoofSegment {
        var distance: Double = 0
        var peak: Double = 0
        var jumped = false
        for k in 1..<max(fixes.count, 1) {
            let a = fixes[k - 1], b = fixes[k]
            let d = SpoofGeo.meters(a.lat, a.lng, b.lat, b.lng)
            distance += d
            let dt = b.t.timeIntervalSince(a.t)
            if dt > jumpSeconds {
                // A jump-cut. Its distance still counts (it IS ground the story covered) but its
                // "speed" is an artefact of how long the app was away, so it never sets the peak.
                jumped = true
            } else if dt >= 1 {
                peak = max(peak, d / dt)
            } else if d > 1_000 {
                // Two fixes a second apart, a kilometre apart: a teleport, not a sprint.
                jumped = true
            }
        }
        let start = fixes[0].t
        let end = fixes[fixes.count - 1].t
        let duration = max(0, end.timeIntervalSince(start))
        return SpoofSegment(
            id: "move-\(start.timeIntervalSince1970)",
            kind: .move,
            dwellNumber: nil,
            start: start,
            end: end,
            coordinates: fixes.map(\.coordinate),
            centroid: mean(fixes),
            distanceMeters: distance,
            averageSpeedMps: duration > 0 ? distance / duration : 0,
            peakSpeedMps: peak,
            fixCount: fixes.count,
            sources: uniqueSources(fixes),
            containsJump: jumped
        )
    }

    private static func number(_ segments: [SpoofSegment]) -> [SpoofSegment] {
        var n = 0
        return segments.map { segment in
            guard segment.kind == .dwell else { return segment }
            n += 1
            return SpoofSegment(id: segment.id,
                                kind: segment.kind,
                                dwellNumber: n,
                                start: segment.start,
                                end: segment.end,
                                coordinates: segment.coordinates,
                                centroid: segment.centroid,
                                distanceMeters: segment.distanceMeters,
                                averageSpeedMps: segment.averageSpeedMps,
                                peakSpeedMps: segment.peakSpeedMps,
                                fixCount: segment.fixCount,
                                sources: segment.sources,
                                containsJump: segment.containsJump)
        }
    }

    /// Plain arithmetic mean. Fine because a dwell is by definition inside an 80 m circle, where the
    /// spherical correction is far below the accuracy of anything feeding it. (It would NOT be fine
    /// across the anti-meridian, which is exactly why it's only ever used on a dwell.)
    private static func mean(_ fixes: [SpoofFix]) -> CLLocationCoordinate2D {
        guard !fixes.isEmpty else { return CLLocationCoordinate2D(latitude: 0, longitude: 0) }
        let n = Double(fixes.count)
        return CLLocationCoordinate2D(latitude: fixes.reduce(0) { $0 + $1.lat } / n,
                                      longitude: fixes.reduce(0) { $0 + $1.lng } / n)
    }

    private static func uniqueSources(_ fixes: [SpoofFix]) -> [SpoofFixSource] {
        var seen = Set<SpoofFixSource>()
        var out: [SpoofFixSource] = []
        for fix in fixes where !seen.contains(fix.src) {
            seen.insert(fix.src)
            out.append(fix.src)
        }
        return out
    }
}

// MARK: - The reading side

/// What TimelineView binds to: the day index, the fixes for the selected day, the cached dwell
/// labels, and the two delete verbs.
///
/// Deliberately thin. All the state that matters is on disk and all the maths is in
/// `SpoofTimelineRollup`; this exists so a SwiftUI view has something to observe.
@MainActor
final class SpoofTimeline: ObservableObject {
    static let shared = SpoofTimeline()

    /// Newest day first — the order the scrubber shows them in.
    @Published private(set) var days: [SpoofTimelineDay] = []
    @Published private(set) var isLoadingIndex = false

    /// Reverse-geocoded dwell labels, keyed by `PlaceLabelService.key` (~110 m cells). Persisted
    /// because the geocoder is a per-process rate-limited budget shared with Places and the search
    /// header: re-asking for last week's stops every time the screen opens would spend that budget on
    /// an answer we already had.
    @Published private(set) var placeLabels: [String: String] = [:]

    /// Cells we've asked `PlaceLabelService` about this launch, so the harvester knows which of its
    /// published answers are ours to keep.
    private var requestedLabelKeys: Set<String> = []
    private var cancellables = Set<AnyCancellable>()

    /// User-facing switch. Reading is cheap; the writer reads the same key off the main thread.
    var isRecordingEnabled: Bool {
        get {
            guard let value = UserDefaults.standard
                .object(forKey: SpoofTimelineRecorder.enabledKey) as? Bool else { return true }
            return value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SpoofTimelineRecorder.enabledKey)
            objectWillChange.send()
        }
    }

    private init() {
        loadLabels()
        refresh()

        NotificationCenter.default.publisher(for: SpoofTimelineRecorder.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Harvest labels as the shared geocoder answers. Only for cells WE asked about — the service
        // is shared, and hoovering up every screen's lookups would grow this file without bound.
        PlaceLabelService.shared.$labels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] labels in self?.harvest(labels) }
            .store(in: &cancellables)

        #if canImport(UIKit)
        // Settle the index before iOS suspends us. Fix lines are already on disk (written straight
        // through), so this only saves the summary — but an index that lags the files makes a day
        // look empty until the next write.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in SpoofTimelineRecorder.flush() }
            .store(in: &cancellables)
        #endif
    }

    // MARK: Index

    func refresh() {
        isLoadingIndex = days.isEmpty
        SpoofTimelineRecorder.loadIndex { [weak self] rows in
            guard let self else { return }
            self.days = rows
            self.isLoadingIndex = false
        }
    }

    func fixes(for day: String, completion: @escaping ([SpoofFix]) -> Void) {
        SpoofTimelineRecorder.loadFixes(day: day, completion: completion)
    }

    // MARK: Deleting — and it really is deleting

    func wipeEverything(completion: (() -> Void)? = nil) {
        SpoofTimelineRecorder.wipeEverything { [weak self] in
            guard let self else { completion?(); return }
            self.placeLabels.removeAll()
            self.requestedLabelKeys.removeAll()
            try? FileManager.default.removeItem(at: SpoofTimelineFiles.labelsURL)
            self.days = []
            completion?()
        }
    }

    func wipeDay(_ day: String, completion: (() -> Void)? = nil) {
        SpoofTimelineRecorder.deleteDay(day) { [weak self] in
            self?.refresh()
            completion?()
        }
    }

    // MARK: Dwell labels

    /// The cached words for a dwell centroid, or nil if we've never resolved it. PURE — safe in a
    /// view body. Call `requestLabel(for:)` from `.onAppear`/`.task` to start the lookup.
    func label(for coordinate: CLLocationCoordinate2D) -> String? {
        placeLabels[PlaceLabelService.key(for: coordinate)]
    }

    /// Ask for a dwell's label. Idempotent, and lazy on purpose: only the dwells actually on screen
    /// are ever geocoded, and only once per ~110 m cell for the life of the install.
    func requestLabel(for coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let key = PlaceLabelService.key(for: coordinate)
        guard placeLabels[key] == nil else { return }
        requestedLabelKeys.insert(key)
        // Already answered this launch (another screen asked)? Take it now — the publisher won't fire
        // again for a value it has already delivered.
        if let existing = PlaceLabelService.shared.labels[key] {
            store(key: key, text: existing.display)
            return
        }
        PlaceLabelService.shared.resolve(coordinate)
    }

    private func harvest(_ labels: [String: PlaceLabel]) {
        var changed = false
        for key in requestedLabelKeys where placeLabels[key] == nil {
            guard let label = labels[key] else { continue }
            placeLabels[key] = label.display
            changed = true
        }
        if changed { saveLabels() }
    }

    private func store(key: String, text: String) {
        guard placeLabels[key] != text else { return }
        placeLabels[key] = text
        saveLabels()
    }

    private func loadLabels() {
        guard let data = try? Data(contentsOf: SpoofTimelineFiles.labelsURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        placeLabels = decoded
    }

    private func saveLabels() {
        // Bounded like every other cache here: a heavy traveller shouldn't grow a labels file for
        // days that retention has already deleted.
        if placeLabels.count > 400 {
            placeLabels = Dictionary(uniqueKeysWithValues: placeLabels.prefix(400).map { ($0.key, $0.value) })
        }
        let snapshot = placeLabels
        SpoofTimelineRecorder.queue.async {
            SpoofTimelineFiles.ensureDirectories()
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: SpoofTimelineFiles.labelsURL, options: .atomic)
        }
    }

    // MARK: Small shared helpers

    /// Whether two instants fall on different calendar days. Used by the coalescer so the last fix
    /// before midnight can't suppress the first fix after it (which would leave the new day's file
    /// starting several minutes late).
    nonisolated static func dayKeyDiffers(_ a: Date, _ b: Date) -> Bool {
        SpoofTimelineFiles.dayKey(for: a) != SpoofTimelineFiles.dayKey(for: b)
    }
}

// MARK: - Formatting helpers shared with the view

extension SpoofSegment {
    /// "2:14 PM – 2:31 PM"
    var timeRangeText: String {
        let from = start.formatted(date: .omitted, time: .shortened)
        let to = end.formatted(date: .omitted, time: .shortened)
        return from == to ? from : "\(from) – \(to)"
    }

    var durationText: String { SpoofTimelineFormat.duration(duration) }
}

enum SpoofTimelineFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }

    /// Metres under a kilometre, kilometres above — and honouring the app's mph preference, since a
    /// user who reads speeds in mph reads distances in miles.
    static func distance(_ meters: Double, useMiles: Bool) -> String {
        if useMiles {
            let feet = meters * 3.280839895
            if feet < 1000 { return "\(Int(feet.rounded())) ft" }
            return String(format: "%.1f mi", meters / 1609.344)
        }
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", meters / 1000)
    }

    static func speed(_ mps: Double, useMph: Bool) -> String {
        String(format: "%.1f %@",
               SpeedFormat.fromMps(mps, useMph: useMph),
               SpeedFormat.unitLabel(useMph: useMph))
    }
}

// MARK: - A note for whoever touches CooldownJournal next
//
// CooldownJournal's header states the same "every field added after v1 must decode with a default"
// rule this file follows, but its structs rely on Swift's SYNTHESISED decoder to honour it. It does
// not: a non-optional stored property with a default value still decodes through `decode(_:forKey:)`
// and throws `keyNotFound` when the key is absent, and `CooldownJournal.load()` turns any throw into
// "start fresh". Adding one non-optional field to `CooldownEntry` or `CooldownAccount` would
// therefore delete every existing user's cooldown history on upgrade — silently, exactly once, with
// no way to get it back. Verified against the toolchain, not assumed. Out of scope here (that file
// belongs to another task), but it wants the same hand-written `decodeIfPresent` initialisers.
