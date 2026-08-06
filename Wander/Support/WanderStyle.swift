//
//  WanderStyle.swift
//  Wander
//
//  Shared design language so Teleport / Joystick / Route feel like one app:
//  a floating control card, a consistent center crosshair for placing points,
//  one brand color, and a single set of icons.
//

import SwiftUI

enum Wander {
    static let brand = Color(red: 0.094, green: 0.373, blue: 0.647)   // #185FA5

    /// The brand blue as an *adaptive* colour (Assets → AccentColor): #185FA5 in light, a
    /// luminance-lifted #5EA6E8 in dark, because the raw brand is too dark to read against a
    /// near-black background. `Wander.brand` stays the fixed literal so existing call sites and
    /// map overlays are untouched — reach for `accent` for anything sitting on a system surface.
    ///
    /// The same asset is wired as the target's global accent (ASSETCATALOG_COMPILER_GLOBAL_
    /// ACCENT_COLOR_NAME), which is the real fix for the "two different apps" problem: before
    /// this asset existed, every untinted Toggle / Link / Button fell back to system blue.
    static let accent = Color("AccentColor")

    // MARK: - Semantic status
    //
    // WHY: status colour was raw and meaningless — .orange 62×, .green 40×, .red 31×, .blue 19×
    // with no shared rule, so orange meant "warning" on one screen and "active" on another.
    // These four are the ONLY status colours. Pick by MEANING, never by hue.

    /// Status a screen can report about one thing. Use `Wander.Status` when the state is
    /// modelled; use the `Wander.good` / `.caution` / … colours directly for one-offs.
    enum Status {
        /// Working as intended: spoof live, tunnel connected, licence valid.
        case good
        /// Usable but degraded, or needs attention soon: reconnecting, weak accuracy,
        /// approaching a quota. NOT an error — the user can keep going.
        case caution
        /// Stopped or refused: tunnel down, action unavailable, request failed. Something the
        /// user must resolve before continuing.
        case blocked
        /// Off / not started / not applicable. Deliberately grey so "idle" never reads as a
        /// problem — half the app's .orange was really this.
        case inactive

        var color: Color {
            switch self {
            case .good:     return Wander.good
            case .caution:  return Wander.caution
            case .blocked:  return Wander.blocked
            case .inactive: return Wander.inactive
            }
        }

        /// The matching SF Symbol, so a status never depends on colour alone (colour-blind users
        /// and glanceability both need the shape).
        var symbol: String {
            switch self {
            case .good:     return "checkmark.circle.fill"
            case .caution:  return "exclamationmark.triangle.fill"
            case .blocked:  return "xmark.octagon.fill"
            case .inactive: return "circle.dashed"
            }
        }

        /// The haptic this status should carry when it becomes true.
        var feedback: WanderFeedback {
            switch self {
            case .good:     return .success
            case .caution:  return .warning
            case .blocked:  return .failure
            case .inactive: return .light
            }
        }
    }

    /// Working as intended. Light #0E7A4B / dark #3FD69B — a deep green in light mode (system
    /// green fails contrast on white) and a lifted mint in dark.
    static let good = Color("WanderGood")
    /// Degraded but usable. Light #9C5500 / dark #FFB84D. Amber, not orange-red, so it is
    /// visibly *not* an error. The light value is a notch darker than the obvious amber so it
    /// still clears 4.5:1 *inside a status chip*, where the text sits on a 12% tint of itself
    /// rather than on plain white.
    static let caution = Color("WanderCaution")
    /// Stopped or refused. Light #BE2D22 / dark #FF6B5C.
    static let blocked = Color("WanderBlocked")
    /// Off / idle / not applicable. Light #636366 / dark #9A9AA0.
    ///
    /// WHY NOT PLAIN SYSTEM GREY: this token is used for 12pt CHIP TEXT, not just for a dot, and
    /// that text sits on a 12% tint of itself. The obvious greys fail WCAG AA there — #8A8A8E
    /// measures 3.4:1 on white, and a #7A7A80 dark variant that looks fine on pure black drops to
    /// 3.5:1 on the #1C1C1E card surface. These two measure 5.1:1 and 5.0:1 *in the chip*. Being
    /// the most-used status (half the app's `.orange` was really this), it is the last one that
    /// can afford to be unreadable.
    static let inactive = Color("WanderInactive")

    // MARK: - Surfaces
    //
    // WHY: cards were built from ad-hoc `.regularMaterial` / `Color(.systemGray6)` / opacity
    // guesses, so two cards on the same screen could sit at different depths. Two tokens is
    // all the depth this app needs — hierarchy comes from TYPE, not from boxes.

    /// The fill for a card or grouped row sitting on `canvas`. White / #1C1C1E.
    static let surface = Color("WanderSurface")
    /// The page behind the cards. #F2F2F7 / black.
    static let canvas = Color("WanderCanvas")
    /// Hairline between/around surfaces. Derived, not an asset, so it tracks the system's
    /// separator in both appearances.
    static let hairline = Color.primary.opacity(0.08)

    /// The colour of supporting text — what `wanderDetail()` and `wanderMicro()` paint with.
    ///
    /// 🔴 A CONCRETE COLOUR ON PURPOSE, not `.secondary`. This is the system's own secondary
    /// label, so it is the same grey `.secondary` resolves to on a plain background and it still
    /// adapts to light/dark — but it is NOT a `HierarchicalShapeStyle`, and that is the point.
    ///
    /// Every floating map panel is a `WanderCard`, and `WanderCard` fills itself with
    /// `MapModeChrome.panelMaterial`. `.background(Material)` publishes `backgroundMaterial` into
    /// the environment, and SwiftUI then resolves hierarchical styles — `.secondary`, `.tertiary`,
    /// and `Color.secondary`, which is hierarchical-backed — through its VIBRANCY path. Measured
    /// in the Joystick panel on an iPhone 17 Pro: `.secondary`, `.tertiary` and `Color.secondary`
    /// all laid out at full width and drew NOTHING AT ALL, while `.primary` and this colour drew
    /// normally; re-clearing `backgroundMaterial` on the same `Text` brought `.secondary` back,
    /// which is what pins the cause on the material rather than on the font or the call site.
    ///
    /// The visible symptom was the Joystick speed readout rendering as a bare "6" with no unit,
    /// but it was never limited to that: it silently blanked EVERY `WanderPanelNote` advisory in
    /// all three map panels, because those go through `wanderDetail()`.
    ///
    /// So: supporting text in this app takes a colour, not a hierarchy level. A raw
    /// `.foregroundStyle(.secondary)` inside a panel is the bug, and there are still some — see
    /// the note on `wanderDetail()`.
    static let secondaryText = Color(uiColor: .secondaryLabel)

    enum Icon {
        static let teleport = "mappin.and.ellipse"
        static let joystick = "dpad.fill"
        static let route = "car.fill"
        static let settings = "gearshape.fill"
        static let setHere = "mappin"
        static let simulate = "location.fill"
        static let stop = "stop.fill"
        static let play = "play.fill"
        static let pause = "pause.fill"
        static let add = "plus.circle.fill"
        static let clear = "trash"
        static let search = "magnifyingglass"

        /// The "…" that holds the long tail of a bar that only has room for a couple of glyphs.
        /// Used by `MapModeToolbar` — the map tabs' shared navigation bar. Circled rather than
        /// bare so it reads as a tappable control against a moving map, where a bare ellipsis
        /// disappears into whatever is underneath it.
        static let overflow = "ellipsis.circle"

        /// Reading a coordinate FILE into Wander (GPX / KML / GeoJSON / CSV). Pairs with
        /// `Wander.Icon.export`.
        ///
        /// This is the SAME glyph as `Wander.Icon.install`, which is deliberate and is the one
        /// place in the vocabulary that repeats: the Places screen's "Import coordinates" row
        /// already draws `square.and.arrow.down`, and the map toolbar's menu item is a second
        /// entry point to that exact action — two doors into one room have to wear one glyph.
        /// `install` (putting an app build on the device) only ever appears in Settings, so the
        /// two never share a screen.
        static let importFile = "square.and.arrow.down"
    }
}

/// A floating, rounded, translucent control panel that sits over a full-bleed map.
///
/// Every measurement comes from `MapModeChrome` so the Teleport, Joystick and Route panels share
/// one container treatment — same radius, same padding, same material, same shadow. Nothing here
/// is a local number; change it in MapModeChrome and all three move together.
struct WanderCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MapModeChrome.cornerRadius, style: .continuous)
    }
    var body: some View {
        content()
            .padding(MapModeChrome.cardPadding)
            .frame(maxWidth: .infinity)
            .background(MapModeChrome.panelMaterial, in: shape)
            .overlay(shape.strokeBorder(Wander.hairline, lineWidth: 0.5))
            .wanderMapShadow()
            .padding(.horizontal, MapModeChrome.horizontalInset)
            .padding(.bottom, MapModeChrome.bottomInset)
    }
}

// A `hugScrollCard(maxHeight:)` helper used to live here — it measured content and let a card
// shrink to fit. It was DELETED, not left unused, because it is the mechanism that let the three
// map panels agree only once their content overflowed: on a first launch they hugged at ~104,
// ~213 and ~250pt and looked like three different designs. Panel sizing now goes through
// `wanderMapPanel()` (MapModeChrome), which is a fixed frame. If you find yourself wanting the old
// hugging behaviour for a map panel, you want to change `MapModeChrome.panelHeight` instead.

/// The center placement crosshair — the one consistent "you'll drop it here" indicator.
struct MapCrosshair: View {
    var body: some View {
        ZStack {
            Circle().stroke(Wander.brand.opacity(0.9), lineWidth: 3).frame(width: 26, height: 26)
            Circle().fill(Wander.brand).frame(width: 6, height: 6)
            Rectangle().fill(Wander.brand.opacity(0.9)).frame(width: 2, height: 12).offset(y: -22)
        }
        .shadow(color: .black.opacity(0.25), radius: 2)
        .allowsHitTesting(false)
    }
}

/// Consistent primary action button used across all modes.
struct WanderPrimaryButton: View {
    let title: String
    let icon: String
    var role: ButtonRole? = nil
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .font(.wanderLabel)
                .frame(maxWidth: .infinity)
                .frame(height: MapModeChrome.controlHeight)
        }
        .buttonStyle(.borderedProminent)
        // Semantic, not raw `.red`: a destructive primary is the "blocked / stop" status colour,
        // which is the same token the Stop buttons in all three modes now use.
        .tint(role == .destructive ? Wander.blocked : Wander.brand)
        .controlSize(.large)
    }
}

// MARK: - Type scale
//
// THE PROBLEM THIS SOLVES: of ~600 font calls in the app, 376 were caption-or-smaller against
// only 14 .headline. With everything at one size nothing is the answer and nothing is the
// footnote — every card reads as equally unimportant, which is the single biggest reason the app
// looked like a hobby tool.
//
// THE RULE: a screen has ONE `display` (or one `metric`) — the answer the user came for. Rows and
// controls get `label`. Everything supporting gets `detail`. `micro` is for genuinely tertiary
// metadata (timestamps, units already implied by context) and if you're reaching for it more than
// once or twice per screen, you want `detail` instead.
//
// WHY TWO TYPEFACES: SF Rounded for numerics and headline moments — that's the Fitness/Health
// register, warm and confident, which is the "playful consumer tool" read we want. SF Pro for
// body and detail, because rounded terminals cost legibility at small sizes. Every style is
// declared against a Dynamic Type text style (never a raw point size) so it still scales.

extension Font {

    /// The ONE answer on a screen: current coordinates, the big speed, the headline state.
    /// Rounded + bold. If a screen has two of these, one of them is wrong.
    static let wanderDisplay = Font.system(.largeTitle, design: .rounded, weight: .bold)

    /// A numeric readout that lives inside a card — speed, distance, elapsed, altitude.
    /// Monospaced digits so the value doesn't jitter as it ticks (pair with `.wanderTick(_:)`).
    ///
    /// THIS IS THE FOCAL VALUE OF A MAP MODE'S PANEL, and there is exactly one size and one colour
    /// rule for it: this font, at `.primary`. The three modes each answer one question — Joystick
    /// "how fast am I moving", Route "how long does this take", Teleport "where is the pin" — and
    /// they had answered it at three different sizes (`.title` / `.title3` / `.subheadline`) in two
    /// different colours (primary / brand), which is precisely how three screens stop looking like
    /// one app. Brand colour is for things you can TOUCH; the answer is read, not tapped.
    static let wanderMetric = Font.system(.title, design: .rounded, weight: .semibold).monospacedDigit()

    /// Card and section headers — the second level of the hierarchy, still rounded so headline
    /// moments share a voice with the display.
    static let wanderTitle = Font.system(.title3, design: .rounded, weight: .semibold)

    /// Row titles, control labels, button text. SF Pro semibold: this is the workhorse, and the
    /// level the app was most starved of (14 `.headline` calls in the entire codebase).
    static let wanderLabel = Font.system(.headline, design: .default)

    /// Running prose inside a card or sheet.
    static let wanderBody = Font.system(.body, design: .default)

    /// Supporting text under a label — the subtitle, the explanation, the hint. Deliberately
    /// `.subheadline` (15pt) rather than `.caption` (12pt): this is where most of those 376
    /// caption calls actually belonged.
    static let wanderDetail = Font.system(.subheadline, design: .default)

    /// Genuinely tertiary metadata only. Reach for `wanderDetail` first.
    static let wanderMicro = Font.system(.caption, design: .default, weight: .medium)

    /// An arbitrary rounded numeric at a chosen text style — for the rare readout that needs to
    /// sit between `wanderMetric` and `wanderLabel` (a chip value, an inline count).
    static func wanderNumeric(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style, design: .rounded, weight: weight).monospacedDigit()
    }
}

extension View {
    /// The one answer on the screen. Applies `Font.wanderDisplay` at full-contrast primary.
    func wanderDisplay() -> some View {
        font(.wanderDisplay).foregroundStyle(.primary)
    }

    /// A numeric readout. Includes the ticker transition, so a value that changes rolls instead
    /// of cutting — pass the underlying number so SwiftUI knows what changed.
    func wanderMetric<V: Equatable>(_ value: V) -> some View {
        font(.wanderMetric).foregroundStyle(.primary).wanderTick(value)
    }

    /// A numeric readout that never changes (a static figure in a summary).
    func wanderMetric() -> some View {
        font(.wanderMetric).foregroundStyle(.primary)
    }

    /// A card or section header.
    func wanderTitle() -> some View {
        font(.wanderTitle).foregroundStyle(.primary)
    }

    /// A row title or control label.
    func wanderLabel() -> some View {
        font(.wanderLabel).foregroundStyle(.primary)
    }

    /// Running prose.
    func wanderBody() -> some View {
        font(.wanderBody).foregroundStyle(.primary)
    }

    /// Supporting text. Secondary colour is part of the token — the contrast drop is what makes
    /// the label above it read as the focal point.
    ///
    /// USE THIS (or `wanderMicro()`) RATHER THAN A RAW `.foregroundStyle(.secondary)` anywhere
    /// that can end up inside a `WanderCard`: a hierarchical style resolves to nothing at all on
    /// the card's material. `Wander.secondaryText` has the measurements.
    func wanderDetail() -> some View {
        font(.wanderDetail).foregroundStyle(Wander.secondaryText)
    }

    /// Tertiary metadata.
    func wanderMicro() -> some View {
        font(.wanderMicro).foregroundStyle(Wander.secondaryText)
    }
}

// MARK: - Status chip

/// A status pill: symbol + colour + word. Exists so "is it working?" looks identical on every
/// screen, and so status is never communicated by colour alone.
struct WanderStatusChip: View {
    let status: Wander.Status
    let text: String
    /// Set true while the underlying thing is mid-transition (connecting, searching) — the icon
    /// throbs instead of the screen dropping in a bare spinner.
    var isBusy: Bool = false
    /// Opt IN to a haptic when the status changes. Default OFF, and it must stay that way: this
    /// chip is meant to be dropped in everywhere, and several of the states it displays are
    /// driven by background pollers (tunnel health, licence checks). A status that flaps
    /// good ↔ caution across polls would buzz the phone in the user's pocket, with the strong
    /// notification-family patterns, for something the user never did. Turn this on only where
    /// the chip is showing the result of an action the user just took.
    var hapticsOnChange: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.symbol)
                .imageScale(.small)
                .wanderSymbolAccent(on: status)
                .wanderSymbolActive(isBusy)
                // The glyph is a redundant encoding of `text` for sighted users; VoiceOver would
                // otherwise read "checkmark circle fill" BEFORE the actual word.
                .accessibilityHidden(true)
            Text(text)
                .font(.wanderMicro)
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(status.color.opacity(0.12), in: Capsule())
        .wanderAnimation(WanderMotion.quick, on: status)
        .wanderFeedback(status.feedback, on: status, enabled: hapticsOnChange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text))
    }
}

// MARK: - State components
//
// WHY: the app shipped 28 `ProgressView`s against 3 `ContentUnavailableView`s, which means empty
// and loading were the same undifferentiated grey spinner. A user can't tell "there's nothing
// here yet" from "it's thinking" from "it broke". These three cover all of it.

/// The app's empty state. A thin wrapper over `ContentUnavailableView` that enforces the voice:
/// the title says what's missing in plain words, the message says what to do about it, and where
/// there's an obvious next step it ships as a real button rather than an instruction to read.
struct WanderEmptyState: View {
    let title: String
    let icon: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
                .font(.wanderTitle)
        } description: {
            if let message {
                Text(message).font(.wanderDetail)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Wander.brand)
                    .controlSize(.large)
            }
        }
    }
}

/// The app's loading state. Still a spinner — but a *labelled* one, because an unlabelled
/// ProgressView tells the user nothing about what is taking time or whether it can fail.
/// Use `WanderSkeleton` instead when you know the shape of what's arriving.
struct WanderLoadingState: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(Wander.brand)
            Text(message)
                .font(.wanderDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message))
    }
}

/// A placeholder bar shaped like the content that's coming. Preferred over a spinner whenever the
/// layout is known (a list of saved places, a licence row) — the screen keeps its structure, so
/// nothing jumps when real data lands.
struct WanderSkeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .wanderShimmer()
            .accessibilityHidden(true)
    }
}

extension View {
    /// Sweep a soft highlight across a placeholder so it reads as "loading", not "broken".
    /// Honours Reduce Motion by simply not animating.
    func wanderShimmer() -> some View {
        modifier(WanderShimmer())
    }
}

/// WHY IT LOOKS LIKE THIS — two traps this avoids:
///
/// 1. TIME-DRIVEN, NOT STATE-DRIVEN. The obvious version starts a `.repeatForever` animation from
///    `onAppear` by setting `@State phase = 1`. The second time that view appears (tab switch, a
///    lazy container scrolling a row back in) the state is ALREADY 1, nothing changes, no
///    animation starts, and the skeleton sits there as a dead static bar. `TimelineView(.animation)`
///    derives the offset from the clock, so there is no state to go stale and no restart to miss.
///    It also stops on its own when the view leaves the screen or the app backgrounds.
///
/// 2. BLEND, NOT MASK. Clipping the sweep to the content's shape via `.mask(content)` builds a
///    SECOND copy of the content. Harmless for a rounded rectangle, but `wanderShimmer()` is a
///    public extension, so someone will eventually apply it to a real subtree with state or an
///    `onAppear` in it and get it instantiated twice. `.blendMode(.sourceAtop)` inside a
///    `.compositingGroup()` clips to the same alpha with one copy.
private struct WanderShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        let width = max(geo.size.width, 1)
                        TimelineView(.animation) { timeline in
                            let period = WanderMotion.shimmerPeriod
                            let elapsed = timeline.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: period)
                            let progress = CGFloat(elapsed / period)
                            LinearGradient(
                                colors: [.clear, Color.primary.opacity(0.10), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: width * 0.55)
                            // Starts fully off the leading edge, ends fully off the trailing one,
                            // so the band never pops into existence mid-bar.
                            .offset(x: -width * 0.6 + progress * width * 1.65)
                            .blendMode(.sourceAtop)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .compositingGroup()
    }
}
