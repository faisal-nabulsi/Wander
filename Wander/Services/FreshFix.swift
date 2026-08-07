//
//  FreshFix.swift
//  Wander
//
//  ONE job: hand back the device's REAL position, or refuse — never a stale guess dressed up as a
//  current one.
//
//  WHY THIS EXISTS AT ALL. Nothing in the app did this. `CurrentLocation` reads
//  `locations.last?.coordinate` with no accuracy check and no age check, `RealGPSSeeder` does the
//  same behind a 3 s timeout, and two live call sites (`MainTabView`'s walk anchor,
//  `ItineraryRunner.drive`) read the raw cached `CLLocationManager().location` property with no
//  checks whatsoever. For "centre the map here" or "seed a priming fix" that is fine — being a few
//  hundred metres out costs nothing you can see.
//
//  Pause is the one feature where it costs everything. Its whole premise is that the user taps it
//  and WALKS AWAY, so a fix that is quietly ten minutes and half a mile old pins them to a place
//  they have already left, and they will not find out — they are not looking at the phone. That is
//  strictly worse than not freezing at all, so this file's contract is: return a fix we can defend,
//  or return a refusal the UI must put in front of the user.
//
//  WHAT COUNTS AS DEFENSIBLE — an error BUDGET, not a flat accuracy number:
//
//      committedError = horizontalAccuracy + speed × age
//
//  A flat age cap is wrong in both directions. Walking at 1.4 m/s a 15 s old fix is 21 m stale,
//  which is nothing, and rejecting it would fail Pause for no reason. Driving at 13 m/s that same
//  15 s is 195 m stale, which is exactly the "pinned to the shop I already left" bug. Multiplying
//  the age by the reported speed handles both in one expression, and it gets the headline case
//  right for free: someone standing in their kitchen has speed ≈ 0, so an older fix is admitted —
//  which is correct, because a phone that has not moved has given Core Location no reason to
//  produce a newer one.
//
//  THE OUTER STALENESS CEILING (`maxAgeSeconds`) IS NOT REDUNDANT WITH THAT. `speed` is the speed
//  AT THE MOMENT THE FIX WAS TAKEN, and the dangerous fix is precisely the one recorded while
//  standing still somewhere you have since walked away from: speed 0, small accuracy, arbitrarily
//  wrong. The budget alone would accept it. So a fix older than the ceiling is never accepted
//  silently, whatever its speed says — it can only reach the device through the user tapping the
//  explicit "freeze here anyway" escape, where its age is named on the button.
//
//  Everything here is advisory-free: it decides, it does not write. No caller may treat a
//  `Refusal` as "just use the best one" without asking the user first.
//

import CoreLocation

@MainActor
final class FreshFixFinder: NSObject, ObservableObject, CLLocationManagerDelegate {

    // MARK: - The numbers, and why each one is what it is

    /// Accept a fix whose committed error is inside this. The "am I on the right building" bar: a
    /// house or apartment block is 10–25 m across and sits 15–30 m from its neighbours, so 65 m
    /// still lands you on your own street, where 150 m plausibly puts you at the shop on the corner.
    /// It is also where iOS actually delivers INDOORS — a Wi-Fi-assisted indoor fix lands 15–65 m
    /// while a cell-only fix lands 500–3000 m — so the threshold cleanly separates the class of fix
    /// that is useless from the class that is merely imperfect. Deliberately looser than
    /// `kCLLocationAccuracyBest` would imply, because the headline use is indoors, at home, and a
    /// bar only clear-sky GPS could clear would fail in the one place this feature is for.
    static let acceptBudgetMeters: Double = 65

    /// The outdoor early exit. Clear-sky iPhone GPS reports 3–10 m within a second or two, so 25 m
    /// is comfortably above that and still smaller than a house. Hitting it means we stop waiting
    /// immediately and the common outdoor case costs ~1–2 s rather than the full deadline.
    static let earlyAccuracyMeters: Double = 25
    static let earlyAgeSeconds: TimeInterval = 5

    /// Long enough for a cold GPS start to produce something usable, short enough that the user has
    /// not put the phone away. `RealGPSSeeder` uses 3 s, which is right for a fire-and-forget
    /// priming write allowed to fail silently, and far too short for the one fix this whole feature
    /// will be judged on.
    static let deadlineSeconds: TimeInterval = 8

    /// See the file header: the ceiling that the speed term cannot cover. 90 s costs nothing in
    /// practice — with Wi-Fi on, iOS delivers a fresh fix within a second or two even indoors — and
    /// it is the only thing standing between Pause and a "speed 0, accuracy 20 m, recorded at the
    /// café" fix.
    static let maxAgeSeconds: TimeInterval = 90

    // MARK: - Types

    struct Fix {
        let coordinate: CLLocationCoordinate2D
        let horizontalAccuracy: CLLocationAccuracy
        let ageSeconds: TimeInterval
        let speedMps: Double

        /// Accuracy plus how far the device could have travelled since the fix was taken.
        var committedError: Double {
            horizontalAccuracy + max(speedMps, 0) * max(ageSeconds, 0)
        }

        /// What the UI puts on a button: a whole number of metres, never a decimal that implies a
        /// precision we do not have.
        var errorText: String { "±\(Int(committedError.rounded())) m" }
    }

    /// Why we will not hand back a fix. Every one of these has to reach the user — none of them may
    /// be swallowed into "try the best we have".
    enum Refusal: Error, Equatable {
        /// Location permission is denied/restricted. There is no real fix to read at all.
        case notAuthorized
        /// Precise Location is OFF. `SnapBackWatcher` documents the reason this is fatal rather
        /// than merely poor: reduced accuracy is fuzzed by a STABLE per-app offset that can sit
        /// hundreds of metres to over a kilometre from the true point. Stable means it will not
        /// average out, so no amount of waiting fixes it — and `horizontalAccuracy` does not
        /// reliably report the fuzz, so the error budget above would happily accept a fix that is
        /// 800 m wrong. It has to be checked separately, against `accuracyAuthorization`.
        case reducedAccuracy
        /// The deadline passed with nothing inside budget. Carries the best we did see so the UI
        /// can show it, with its real error, behind an explicit tap.
        case noGoodFix
    }

    // MARK: - Live state, for the progress sheet

    /// The best fix seen so far this run (smallest committed error). Drives the live "±180 m —
    /// waiting for ±65 m" readout, and is what the "freeze here anyway" escape would use.
    @Published private(set) var best: Fix?
    /// When this run started, so the sheet can draw the deadline as a ring.
    @Published private(set) var startedAt: Date?
    @Published private(set) var isRunning = false

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Result<Fix, Refusal>, Never>?
    private var deadlineTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    // MARK: - The one entry point

    /// Acquire a fix we can defend, or refuse. Never writes anything anywhere.
    ///
    /// Callers MUST NOT start writing to the device while this is running: the whole point is that
    /// nothing lands on the device until a fix has passed, so the user can never end up frozen at a
    /// point we were still unsure about.
    func find() async -> Result<Fix, Refusal> {
        cancel()
        best = nil
        startedAt = Date()
        isRunning = true

        return await withCheckedContinuation { cont in
            self.continuation = cont

            switch manager.authorizationStatus {
            case .denied, .restricted:
                finish(.failure(.notAuthorized))
                return
            case .notDetermined:
                // Ask, and let `locationManagerDidChangeAuthorization` pick the run back up. The
                // deadline below still applies, so an unanswered prompt fails closed rather than
                // hanging.
                manager.requestWhenInUseAuthorization()
            default:
                if manager.accuracyAuthorization == .reducedAccuracy {
                    finish(.failure(.reducedAccuracy))
                    return
                }
                manager.startUpdatingLocation()
            }

            self.deadlineTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.deadlineSeconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.finish(.failure(.noGoodFix))
            }
        }
    }

    /// Abandon a run in progress (the user backed out of the sheet). Resolves any pending await
    /// with `noGoodFix` so no caller is ever left suspended.
    func cancel() {
        guard isRunning else { return }
        finish(.failure(.noGoodFix))
    }

    // MARK: - Judging a fix

    /// Would we freeze on this without asking? Both clauses mean "accept now"; the early one exists
    /// so a good outdoor fix does not sit through a budget comparison it obviously passes.
    private func isAcceptable(_ fix: Fix) -> Bool {
        guard fix.horizontalAccuracy >= 0 else { return false }   // negative == invalid, per Apple
        guard fix.ageSeconds <= Self.maxAgeSeconds else { return false }
        if fix.horizontalAccuracy <= Self.earlyAccuracyMeters, fix.ageSeconds <= Self.earlyAgeSeconds {
            return true
        }
        return fix.committedError <= Self.acceptBudgetMeters
    }

    private func finish(_ result: Result<Fix, Refusal>) {
        deadlineTask?.cancel()
        deadlineTask = nil
        manager.stopUpdatingLocation()
        isRunning = false
        let cont = continuation
        continuation = nil
        cont?.resume(returning: result)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        Task { @MainActor in
            guard self.isRunning else { return }
            switch status {
            case .denied, .restricted:
                self.finish(.failure(.notAuthorized))
            case .authorizedAlways, .authorizedWhenInUse:
                if accuracy == .reducedAccuracy {
                    self.finish(.failure(.reducedAccuracy))
                } else {
                    self.manager.startUpdatingLocation()
                }
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Read every field here, on the delivery thread, so the age is measured against the moment
        // the fix arrived rather than against whenever the main actor gets round to us.
        let fix = Fix(
            coordinate: location.coordinate,
            horizontalAccuracy: location.horizontalAccuracy,
            ageSeconds: max(0, -location.timestamp.timeIntervalSinceNow),
            speedMps: location.speed
        )
        Task { @MainActor in self.consider(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Deliberately silent: a transient failure is not a refusal, and the deadline already
        // covers "nothing usable ever arrived".
    }

    private func consider(_ fix: Fix) {
        guard isRunning else { return }
        guard CLLocationCoordinate2DIsValid(fix.coordinate), fix.horizontalAccuracy >= 0 else { return }
        // Keep the best candidate for the "freeze here anyway" escape and the live readout. A fix
        // too stale to accept is also too stale to offer, so it is not allowed to become `best`.
        if fix.ageSeconds <= Self.maxAgeSeconds,
           best.map({ fix.committedError < $0.committedError }) ?? true {
            best = fix
        }
        if isAcceptable(fix) { finish(.success(fix)) }
    }
}
