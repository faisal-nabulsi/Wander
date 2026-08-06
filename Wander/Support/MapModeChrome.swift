//
//  MapModeChrome.swift
//  Wander
//
//  THE ONE PLACE that decides how a map mode's screen is laid out — the navigation treatment, the
//  bottom control panel's height and the placement crosshair's position. Teleport
//  (MapSelectionView), Joystick (WalkModeView) and Route (RouteModeView) all read from here and
//  nowhere else.
//
//  WHY THIS FILE EXISTS
//
//  The three modes had drifted into three different layouts of the same screen:
//
//    crosshair   Teleport: a COMPUTED lift measured from the card's live top edge
//                Joystick: no lift at all — dead centre
//                Route:    a HARDCODED 0.18 of screen height
//    panel cap   Teleport: 0.34 × screen    Joystick: 0.55 × screen    Route: 0.44 × screen
//
//  So the crosshair jumped and the panel resized every time the user changed tab. Three rules that
//  happened to be near each other is not consistency — it is three chances to drift apart again.
//  Here there is ONE panel height and ONE crosshair rule, and the crosshair is DERIVED from the
//  panel height, so the two can never disagree: change the panel and the crosshair follows.
//
//  DO NOT add a per-mode override, and do not re-introduce a `crosshairLift` constant in a view.
//  The panel is ONE size in every state — there is deliberately no `expanded:` escape hatch any
//  more; see "Panel height" below for why the disclosure sections lost theirs.
//
//  THE NAVIGATION RULE — all three modes are a `NavigationStack` owning a full-bleed map, with
//  `.navigationTitle(…)` at `.navigationBarTitleDisplayMode(.inline)`. That is the whole rule, and
//  every one of the three states it for itself in three lines (the tab bar already hosts the views,
//  so there is no single parent to hoist the stack into without double-wrapping the other tabs).
//
//  It matters for layout, not just for looks: an inline bar is ~44pt where a large title is ~96,
//  so a mode that picks the other one has a different amount of visible map above the crosshair.
//  `topChrome` below is the one place the bar's height enters the geometry.
//
//  The bar carries THE SAME THREE ITEMS in all three modes, from one definition — see
//  `mapModeToolbar` in Views/MapModeToolbar.swift. Teleport used to hang five buttons off it while
//  Joystick and Route hung none, which made the top of the app change shape depending on which map
//  mode you were on. A button that belongs up here belongs up here on all three, or on none; that
//  is why there is one shared definition and no per-mode `.toolbar`.
//
//  Toolbar ITEMS do not change the bar's height — `navBarHeight` below is still the inline 44pt,
//  and the crosshair derived from it is unaffected. A large title or a `.searchable` field WOULD
//  change it.
//

import SwiftUI
import UIKit
import CoreLocation
import MapKit

enum MapModeChrome {

    // MARK: - Container treatment
    //
    // Every floating panel in the app is drawn from these — one corner radius, one padding, one
    // material, one shadow. `WanderCard` is the main consumer (and the only one for a PANEL);
    // the map-style button borrows the nested-control radius and the panel material so it reads as
    // part of the same family. Nothing should draw its own rounded-rectangle-over-map by hand.

    /// Corner radius of a floating control panel.
    static let cornerRadius: CGFloat = 24
    /// Inset from the panel's edge to its content.
    static let cardPadding: CGFloat = 16
    /// Gap between the panel and the screen edges.
    static let horizontalInset: CGFloat = 12
    /// Gap between the panel and whatever is under it (tab bar / home indicator).
    static let bottomInset: CGFloat = 12

    /// Corner radius of a control NESTED INSIDE — or floating beside — a panel: the AI teleport
    /// field, the address search field and its results, the Look Around strip, the map-style
    /// button. One step tighter than `cornerRadius` so a nested control reads as part of its card
    /// rather than as a second, smaller card.
    ///
    /// There are exactly TWO ROUNDED-RECTANGLE radii in a map mode, this and `cornerRadius`.
    /// (Pills — status chips, mode selectors — are `Capsule`, a different shape rather than a
    /// third radius; a capsule reads as a pill at any height, so it can't drift.)
    ///
    /// Teleport used to show three (24 on the card, 12 on the map-style button, 10 on the AI bar),
    /// which is the same class of drift as three panel heights — just at a scale you feel rather
    /// than name. The AI bar was folded onto this token first and `AddressSearchBar` — which
    /// renders in ALL THREE panels, directly beside it — kept its 10 for a round longer, so every
    /// mode still showed a 10 touching a 12. Both are on the token now; a new hardcoded radius in
    /// a map panel makes the paragraph above a lie.
    static let innerCornerRadius: CGFloat = 12
    /// Inset from a nested control's edge to its content.
    static let innerPadding: CGFloat = 10

    // MARK: - Materials
    //
    // TWO materials, pairing with the two radii: one for a surface that floats over the MAP, one
    // for a control nested INSIDE such a surface. Thin-on-regular was already the relationship the
    // AI bar drew — but it was a literal typed at each call site, with nothing anywhere saying
    // WHICH material a nested control takes, so the next control was free to pick a different one
    // (and, being untokenized, its radius drifted along with it). Naming the rule is the fix.

    /// The fill of a map mode's floating surfaces: the control panel (`WanderCard`) and the
    /// map-style button. Same material, same shadow, same family.
    static let panelMaterial: Material = .regularMaterial

    /// The fill of a control NESTED INSIDE a panel — the AI teleport bar, the address search field
    /// and its results list, the Look Around placeholder. Deliberately thinner than
    /// `panelMaterial`: on top of a `.regularMaterial` card it reads as a recess in that card,
    /// where a second `.regularMaterial` would read as a second card.
    static let innerMaterial: Material = .thinMaterial

    /// Apple's minimum comfortable touch target, and the size of a square icon button that floats
    /// over the map (the map-style switcher).
    static let tapTarget: CGFloat = 44

    // MARK: - Elevation
    //
    // ONE shadow recipe for everything that floats over the map — the control panel and the
    // map-style button both. Two recipes (0.14/14/6 on the card, 0.12/8/3 on the button) meant two
    // apparent heights above the map on a single screen.

    static let shadowOpacity: Double = 0.14
    static let shadowRadius: CGFloat = 14
    static let shadowY: CGFloat = 6

    // MARK: - Spacing + control rhythm
    //
    // One vertical rhythm across all three panels. Before this they ran at 8 / 12 / 14pt, which is
    // exactly the kind of difference you can't name but can see the moment you switch tabs.

    /// Between the major rows of a control panel (search bar → controls → primary action), and
    /// between two peer ACTION BUTTONS sharing a line — a Preview/Drive or Stop/Play pair is two
    /// major elements side by side, not two chips, so it takes the major gap in both axes.
    static let rowSpacing: CGFloat = 12
    /// Inside a row group — a label and the control it describes, a title and its hint, a glyph
    /// and the sentence it belongs to.
    static let groupSpacing: CGFloat = 6
    /// Between chips / segmented items on one line.
    static let chipSpacing: CGFloat = 6
    //
    // THERE ARE EXACTLY THREE GAPS, and they are the three above. Do NOT write
    // `chipSpacing + 4` or `groupSpacing + 2` at a call site: an arithmetic offset on a token is a
    // magic number wearing a token's name, and it re-creates the 6/8/10 spread this file was
    // written to collapse. If a new level is genuinely needed, name it here.
    /// The label height every bordered / prominent action button in a panel is built around.
    /// Paired with `.controlSize(.large)` a `WanderPrimaryButton` MEASURES 60pt — not the ~44 this
    /// comment claimed until 2026-08-04. Measured with `UIHostingController.sizeThatFits` on iOS
    /// 18.6 and 26.5, identical on both. The old figure was an estimate that was never checked, and
    /// every content total below that contains a primary button inherited the same 16pt shortfall.
    static let controlHeight: CGFloat = 30

    // MARK: - Embedded lists
    //
    // A `List` inside a panel can't size itself, so it needs an explicit frame. That frame is a
    // token, not a magic number typed at the call site: Route's stop list was
    // `min(count * 44 + 8, 200)`, i.e. three unexplained constants sitting inside the one panel
    // whose height everything else is derived from.

    /// One row of an embedded list — the tap target, so a stop is as easy to hit as anything else.
    static let listRowHeight: CGFloat = tapTarget
    /// Tallest an embedded list may grow before it scrolls inside itself.
    static let listMaxHeight: CGFloat = 200

    /// Height for an embedded `List` of `rows` rows. The `groupSpacing` is the list's own top/bottom
    /// breathing room, so the last row doesn't sit flush against the frame's edge.
    static func listHeight(rows: Int) -> CGFloat {
        min(listMaxHeight, CGFloat(max(rows, 1)) * listRowHeight + groupSpacing)
    }

    // MARK: - Panel height
    //
    // ONE height for all three modes — but sized to REAL CONTENT, not to a fraction of the screen.
    // A percentage is sized to nothing. The previous rule (0.42 of the window) gave a 358pt box on
    // an iPhone 15, and the Teleport panel it holds is 214pt of content at rest: roughly the bottom
    // THIRD of the card was blank, and the Joystick's 98pt sat in a card that was three quarters
    // empty. That is what a screen fraction buys — a number that tracks the phone instead of the
    // thing it is holding.
    //
    // MEASURED CONTENT, AT REST — the state each mode is in when you land on it (no pin, no start
    // point, no waypoints), inside the 16pt card padding, at the 12pt row rhythm above. These are
    // the numbers the height below is chosen FROM; recompute them if you add or remove a row.
    //
    //   Teleport, no pin     search 42 + AI bar 42 + Find-My toggle 50 + "Set pin here" 60
    //                        + 3 gaps (36)                                         = 234.33 pt
    //   Route, no waypoints  search 42 + "Add point" 60 + group 6 + import/clear row 20
    //                        + mode group 51 + pace group 95 + "More options" 50
    //                        + Preview/Drive 60 + 5 gaps (60)                       = 444.67 pt
    //                        (MEASURED 2026-08-05, iPhone 16 / iOS 18.6 and iPhone 17 / iOS 26.5,
    //                        identical to 0.34pt. Was 364.33 while "Add point" was a text button
    //                        sharing a line with Import/Clear; the ≈354 written here before that
    //                        was an estimate, never measured.)
    //   Joystick, no start   search 42 + "Set start point" 60 + speed readout 33.67
    //                        + groupSpacing 6 + presets 28.33 + slider 31
    //                        + 3 gaps (36)                                         = 237.00 pt
    //
    // And once you are WORKING in a mode, all three are far taller than any panel that leaves the
    // map usable — Teleport with a pin ≈ 466, Route with stops ≈ 456, Joystick walking ≈ 484, i.e.
    // ~55% of an 852pt phone. So SOMETHING always scrolls; the only real question is which state
    // the box is sized for.
    //
    // THE CHOICE: fit TELEPORT AT REST snugly — and let anything longer scroll. Teleport is the tab
    // the app opens on and the middle of the three, so it is the honest reference:
    //
    //   Teleport at rest  234.33 in 240 — 5.67pt of slack.
    //   Route at rest     444.67 in 240 — scrolls; Preview/Drive is one flick down.
    //   Joystick at rest  237.00 in 240 — 3.00pt of slack.
    //
    // ⚠️ ROUTE HAS NO SLACK TO RECLAIM, and a 2026-08-05 pass went looking for some on the strength
    // of screenshots that read as "spacious". MEASURED at the panel's real content width: Route is
    // 444.67pt at rest, 468.67 at one waypoint and 618.67 at two — it OVERFLOWS this box by 205 to
    // 379pt in every state and has never shown a blank bottom. The suspected cause (an empty
    // `@ViewBuilder` branch such as Route's stops list still eating its row gap) was tested
    // directly and is FALSE: a VStack(spacing: 12) of three 40pt rows measures 144.00pt with zero
    // empty members, with four `if false` inline conditionals, with four empty @ViewBuilder
    // members, with four `EmptyView()` literals, and wrapped in a `Group` carrying
    // `.disabled`/`.opacity` — the same number five times, on iOS 18.6 and 26.5. An empty branch
    // costs exactly nothing. Blank space inside a map panel is a hole in a ROW (a wrapped label, a
    // `Spacer()` in an HStack), not slack in this frame.
    //
    // ⚠️ THE 26pt OF "GIVE" THIS COMMENT USED TO CLAIM DOES NOT EXIST. `restingContent = 214` and
    // `restingSlack = 26` were chosen as "214 of content plus 26 of headroom for larger Dynamic
    // Type". Both halves were wrong: Teleport at rest measures 234.33, so the real headroom is
    // 5.67pt, which is why Teleport begins scrolling ONE Dynamic Type step up. panelHeight still
    // lands on 240 and the app is unchanged — but do not reason from a 26pt cushion that is not
    // there. If that headroom is wanted, the honest lever is raising `restingTarget` for all three
    // modes at once (and recomputing crosshairLift plus the worked examples at the end of this
    // file), NOT trimming one tab.
    //
    // The Joystick's old "IRREDUCIBLE 142pt of slack" claim was also wrong, and is gone: the slack
    // was never irreducible, the rest state was simply under-filled. Its speed controls used to be
    // gated behind having a start point, which is backwards — you choose how fast you will move
    // BEFORE you move. Surfacing them at rest took it from 114pt to 237pt with no change to this
    // shared height. Both resting panels are now within 2.67pt of each other.
    //
    // The two rejected options, so they aren't re-tried: sizing to the BUSIEST resting panel
    // (Route, 338) is what 0.42 effectively was, and it is exactly why Teleport read as a third
    // empty. Sizing under 200 to flatter the Joystick pushes Teleport's own Simulate button below
    // the fold on the default tab. 240 is the point where the tab people actually sit on fits and
    // nothing else is silly.
    //
    // THIS HEIGHT IS A FLOOR AS WELL AS A CAP — see `wanderMapPanel`. An earlier version only
    // capped, letting each panel hug shorter content; the three then agreed only once content
    // overflowed, and on first launch they measured ~104, ~213 and ~250 pt — three visibly
    // different boxes, which is the exact complaint this file exists to answer. The empty space
    // under a sparse panel is the price of a fixed frame for the crosshair to be derived from.

    // WHY THERE IS NO LONGER AN "EXPANDED" HEIGHT — the decision, recorded so it isn't re-litigated.
    //
    // A previous pass let a mode ask for a taller panel while its disclosure was open (Joystick's
    // hands-free section, Route's "More options"): `wanderMapPanel(expanded:)`, a second shared
    // fraction of 0.56. It was shared, so it looked consistent — but only two of the three modes
    // could ever ask for it. Teleport has no disclosure, so on an iPhone 15 the box was 477pt on
    // Route with its options open and 358pt on Teleport, and switching tabs resized it. That is the
    // ORIGINAL complaint ("the box changes size between tabs") surviving in a narrower state.
    //
    // Three ways out: give all three the same expanded state, let expansion scroll WITHIN the
    // canonical height, or drop expansion entirely. The middle one is chosen and it costs nothing,
    // because the panel is ALREADY a fixed-height ScrollView (`WanderMapPanelSizing`) — opening a
    // disclosure simply makes its content taller than the frame, and the frame scrolls. Nothing
    // becomes unreachable; the panel just stops eating another 120pt of map to show a radius picker.
    //
    // It is also the only option that keeps the crosshair honest. The crosshair is derived from the
    // panel height; the old expanded height deliberately did NOT move it, so with a disclosure open
    // the aim point was no longer the midpoint of the visible map. With one height there is one
    // crosshair position, in every state, in all three modes.
    //
    // So: ONE height. If a panel feels cramped, the fix is `restingTarget` below — for all three at
    // once — never a per-mode allowance.

    /// Teleport's measured resting content. The reference the shared height is built from.
    private static let restingContent: CGFloat = 214
    /// Give on top of it, for larger Dynamic Type and a subtitle that wraps one line further.
    private static let restingSlack: CGFloat = 26
    /// What the panel wants to be on any normal device: 240pt of content box.
    private static let restingTarget: CGFloat = restingContent + restingSlack
    /// Ceiling as a share of a SMALL window (an SE, an iPad in Slide Over), so a short window
    /// doesn't hand the whole screen to the panel. It only bites below a ~600pt window — every
    /// phone from an SE up gets the full `restingTarget`, which is the point: one design, not one
    /// per device.
    private static let restingScreenCap: CGFloat = 0.40
    /// …and never collapse to a stub in a genuinely tiny window.
    private static let restingMin: CGFloat = 200

    // MARK: - System chrome
    //
    // WHAT IS MEASURED AND WHAT IS ASSUMED. Stated plainly, because every number below feeds one
    // output (the crosshair) that has no test and fails silently — it just aims at the wrong place.
    //
    //   MEASURED at runtime, from the key window:
    //     • `safeAreaTop`    — status bar / notch. 20 on an SE, 59 on a Dynamic Island phone,
    //                          ~24 on an iPad.
    //     • `safeAreaBottom` — home indicator. 34 on a Face-ID phone, ~20 on a modern iPad, and
    //                          genuinely 0 on a Home-button device.
    //     • `screenHeight`   — the window's height.
    //
    //   ASSUMED, because SwiftUI publishes neither height and there is no supported way to read
    //   them:
    //     • `navBarHeight` — assumes the INLINE navigation bar of "THE NAVIGATION RULE" at the top
    //       of this file. If any mode switches to `.large` (~96pt), adds a `.searchable` field to
    //       its bar, or hides the bar entirely, this becomes wrong by tens of points and NOTHING
    //       fails to compile: the crosshair simply stops being the midpoint of the visible map.
    //     • `tabBarHeight` — assumes MainTabView's plain `TabView` with plain `.tabItem` labels.
    //       Adding an accessory view (a now-playing-style bar) or a bottom toolbar breaks it the
    //       same silent way.
    //
    // Those two are the live assumptions. If you change either of the things they assume, change
    // them here — this is the only place either number exists.

    /// Which idiom we are on. The tab bar's POSITION depends on it, which is why this file has to
    /// care at all — see `systemChrome`.
    private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The window the map modes are actually laid out in. Nil in previews and for the moment
    /// before the first window attaches, so every reader below carries an explicit fallback.
    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
            ?? scenes.compactMap(\.keyWindow).first
    }

    /// Status bar / notch. Falls back to the old middle-of-the-range estimate.
    private static var safeAreaTop: CGFloat { keyWindow?.safeAreaInsets.top ?? 47 }
    /// Home indicator. Falls back to the common case for the idiom.
    private static var safeAreaBottom: CGFloat { keyWindow?.safeAreaInsets.bottom ?? (isPad ? 20 : 34) }

    /// ASSUMED height of the inline navigation bar. See the block comment above.
    private static var navBarHeight: CGFloat { isPad ? 50 : 44 }
    /// ASSUMED height of MainTabView's tab bar. See the block comment above.
    private static var tabBarHeight: CGFloat { isPad ? 50 : 49 }

    /// Everything below the crosshair that is NOT `panelHeight` itself: the system chrome under
    /// the map, plus the card's own padding.
    ///
    /// READ THIS BEFORE CHANGING IT. `panelHeight` sizes the CONTENT inside `WanderCard`, and the
    /// card then draws 16pt of padding above and below that content, so the visible card is
    /// `panelHeight + 32` tall before it has even been positioned. Counting only the tab bar and
    /// home indicator (the original `96`) therefore under-measured the reserved strip by the card's
    /// own padding and put the crosshair below the true midpoint of the visible map.
    ///
    /// 🔴 THE TAB BAR IS NOT ALWAYS DOWN HERE. This target ships for iPad
    /// (TARGETED_DEVICE_FAMILY = "1,2") and iPadOS 18 renders MainTabView's `TabView` ACROSS THE
    /// TOP. The previous constant — a flat `49 + 34` — assumed an iPhone unconditionally, so on
    /// every iPad it reserved 49pt of bar that was not below the map and only ~20pt of home
    /// indicator that was, while also missing the 50pt of tab bar now sitting over the map. Net
    /// effect on an 11-inch iPad: the crosshair aimed ~48pt above the true midpoint, on all three
    /// tabs at once. NOTHING JUMPED when you switched tab, which is exactly why it survived a pass
    /// whose whole complaint was jumping — it was uniformly wrong instead of inconsistently wrong.
    private static var systemChrome: CGFloat { (isPad ? 0 : tabBarHeight) + safeAreaBottom }

    /// Derived from the container tokens rather than typed as a literal, so changing `cardPadding`
    /// or `bottomInset` moves the crosshair with it. (iPhone 15: 16 + 16 + 12 + 83 = 127.)
    private static var bottomChrome: CGFloat { cardPadding * 2 + bottomInset + systemChrome }

    /// Everything ABOVE the map that the user can't see through: the status bar, the inline
    /// navigation bar all three modes carry (see "THE NAVIGATION RULE" at the top) — and on iPad
    /// the tab bar, which lives up here rather than at the bottom.
    ///
    /// The map `.ignoresSafeArea()`, so it really does run the full height of the window and the
    /// bars sit ON it — which is why this belongs in the crosshair maths and not in the panel's.
    /// Before all three modes had a bar this term didn't exist, and the crosshair was placed at the
    /// midpoint of a strip whose top ~90pt was covered.
    ///
    /// Internal rather than private ONLY so `topFloatInset` can be derived from it — no view reads
    /// this directly, and none should.
    static var topChrome: CGFloat { safeAreaTop + navBarHeight + (isPad ? tabBarHeight : 0) }

    /// Top padding for a control that floats at the TOP of a mode's map, clear of the navigation
    /// bar — currently only Route's follow-camera button.
    ///
    /// It lives here because RouteModeView used to type `.padding(.top, 110)`, an INDEPENDENT
    /// SECOND COPY of the `topChrome` assumption: two hand-tuned numbers describing the same bar,
    /// either of which could rot without the other noticing. One copy now, and it tracks the
    /// measured status bar instead of assuming a notched iPhone (it was 46pt too low on an SE).
    static var topFloatInset: CGFloat { topChrome + horizontalInset }

    /// Height of the space the modes are laid out in.
    ///
    /// The WINDOW, not `UIScreen.main.bounds`: on an iPad in Split View, Slide Over or Stage
    /// Manager the screen is the whole display and the app is a fraction of it, so sizing the panel
    /// and the crosshair from the screen would over-size both. Identical to the screen on any
    /// full-screen iPhone or iPad, which is why this is a correction and not a change.
    static var screenHeight: CGFloat { max(keyWindow?.bounds.height ?? UIScreen.main.bounds.height, 1) }

    /// THE canonical height of the bottom control panel. Identical in all three modes, in every
    /// state — there is no expanded variant; see the note above `restingContent`.
    ///
    /// Content-sized first, clamped second: `restingTarget` on any window taller than ~600pt (every
    /// iPhone and iPad), and a share of the window below that.
    static var panelHeight: CGFloat {
        min(restingTarget, max(restingMin, screenHeight * restingScreenCap))
    }

    // MARK: - Crosshair
    //
    // DERIVED from `panelHeight`, never stated independently. The crosshair sits at the vertical
    // MIDPOINT of the map strip the user can actually see: with `reserved` points of panel and
    // system chrome at the bottom of a screen of height H, and `topChrome` points of status +
    // navigation bar over the top, the visible strip runs topChrome … (H − reserved). Its midpoint
    // is (topChrome + H − reserved)/2, so the offset from the screen's centre (H/2) is
    // (topChrome − reserved)/2 — a LIFT of (reserved − topChrome)/2, i.e. the fraction
    // (reserved − topChrome) / 2H of screen height.
    //
    // WORKED EXAMPLES — recompute these if you touch any number above, and fix them here if they
    // stop matching. This file's whole job is one measured number; a comment that disagrees with
    // the code is worse than no comment, because the next person re-derives from the comment.
    // Each line lands on the exact midpoint of the visible strip, which is the check.
    //
    //   SE, H = 667       safe areas 20 / 0 → topChrome 64, systemChrome 49, bottomChrome 93
    //                     panel 240 + 93 = 333 reserved
    //                     lift (333 − 64)/1334 = 0.2017 → offset −134.5 → crosshair 199.0.
    //                     Card top 334; visible strip 64 … 334, midpoint 199. ✓
    //   iPhone 15, H=852  safe areas 59 / 34 → topChrome 103, systemChrome 83, bottomChrome 127
    //                     panel 240 + 127 = 367 → lift 264/1704 = 0.1549 → offset −132.0 →
    //                     crosshair 294.0. Card top 485; strip 103 … 485, midpoint 294. ✓
    //   Pro Max, H=932    same insets → panel 240 + 127 = 367 → lift 264/1864 = 0.1416 → offset
    //                     −132.0 → crosshair 334. Card top 565; strip 103 … 565, midpoint 334. ✓
    //   iPad 11", H=1194  safe areas 24 / 20, tab bar ON TOP →
    //                     topChrome 24 + 50 + 50 = 124, systemChrome 20, bottomChrome 64
    //                     panel 240 → 304 reserved → lift 180/2388 = 0.0754 → offset −90.0 →
    //                     crosshair 507. Card top 890; strip 124 … 890, midpoint 507. ✓
    //
    // Note the iPad line: a content-sized panel on a very tall window gives a SMALL lift (0.075).
    // The lower clamp used to be 0.10 and would have overridden it, putting the crosshair 30pt
    // above the true midpoint — so the floor is now 0, which is what a backstop should be. A lift
    // of 0 simply means "aim at the centre", which is correct when almost nothing is reserved.
    //
    // There is no expanded panel any more (see `restingContent`), so these ARE the worst cases:
    // the crosshair cannot be crowded by a disclosure opening underneath it.
    //
    // The clamps are a backstop against a future height change putting the crosshair off-screen or
    // back under the card.

    /// Distance from the BOTTOM OF THE WINDOW up to the TOP EDGE of the control panel's card —
    /// i.e. the height of the strip the panel plus the system chrome beneath it reserve.
    ///
    /// This is the quantity the crosshair maths has always called `reserved`; it is named here
    /// because a SECOND thing now needs it (a floating control that must stay clear of the panel,
    /// see `panelClearance`), and two expressions of "where the panel's top edge is" is precisely
    /// the drift this file exists to prevent. Same two terms, same order — the crosshair's value
    /// is unchanged by the extraction.
    static var panelTopInset: CGFloat { panelHeight + bottomChrome }

    /// Bottom inset for a control that floats at the bottom of a map mode and must stay CLEAR OF
    /// the control panel — currently MainTabView's global panic button.
    ///
    /// Measured from the BOTTOM SAFE-AREA EDGE, because that is where a bottom-aligned overlay on
    /// MainTabView's `TabView` actually starts: with `.padding(.bottom, 66)` the panic button's
    /// 56pt circle was measured at y 718…774 on an iPhone 17 Pro (window height 874), i.e. its
    /// bottom sat 100pt above the window's bottom — 66 plus the 34pt home indicator. Hence the
    /// `- safeAreaBottom` term; without it a control placed at `panelTopInset` would still land
    /// 34pt low and keep clipping the panel's last row.
    ///
    /// The `+ horizontalInset` is one gap of air, the same gap the panel keeps from the screen
    /// edges, so the button reads as floating beside the panel rather than glued to it.
    static var panelClearance: CGFloat { panelTopInset - safeAreaBottom + horizontalInset }

    /// Fraction of SCREEN HEIGHT the crosshair is lifted above the map's centre.
    static var crosshairLift: CGFloat {
        min(0.34, max(0, (panelTopInset - topChrome) / (2 * screenHeight)))
    }

    /// Point offset applied to the crosshair view.
    static var crosshairOffset: CGFloat { -screenHeight * crosshairLift }

    /// The coordinate actually UNDER the crosshair for a given map region.
    ///
    /// This is the other half of the contract and the reason the two must live together: the
    /// crosshair is lifted in view space, so "the point the user is aiming at" is NOT the map's
    /// geometric centre — it is that centre shifted north by the same fraction of the visible
    /// latitude span. All three modes report their `visibleCenter` through here, so what the user
    /// drops always lands where the crosshair is drawn.
    ///
    /// (Valid because the map `.ignoresSafeArea()` in all three modes, so map height ≈ screen
    /// height and the screen-height fraction maps 1:1 onto the latitude span.)
    ///
    /// 🔴 FOR A SwiftUI `Map` ONLY. `MKCoordinateRegion` carries no idea of which view it came
    /// from, so this overload has to ASSUME the region describes the map's full height and that
    /// `region.center` sits at the view's centre. A SwiftUI `Map` honours both. A UIKit
    /// `MKMapView` honours NEITHER — use `dropPoint(in mapView:)` for one, and see the note
    /// there for the measurements.
    static func dropPoint(in region: MKCoordinateRegion) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: region.center.latitude + crosshairLift * region.span.latitudeDelta,
            longitude: region.center.longitude
        )
    }

    /// Where the crosshair is drawn, in the coordinate space of a FULL-BLEED map view that
    /// `wanderMapCrosshair` is overlaying.
    ///
    /// The overlay is centred on the map and shifted by `crosshairOffset`, so this is that same
    /// offset expressed as a point — the one definition, reused rather than re-derived.
    static func crosshairPoint(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.midY + crosshairOffset)
    }

    /// The coordinate actually UNDER the crosshair on a UIKit `MKMapView`.
    ///
    /// USE THIS, NOT `dropPoint(in region:)`, for an `MKMapView`. Measured on an iPhone 17 Pro
    /// (window 402 × 874) with the map view genuinely full-bleed — `mapView.bounds.height` was
    /// 874, matching `screenHeight` exactly — the region getter still reported:
    ///
    ///     safeAreaInsets / layoutMargins  116 top, 83 bottom
    ///     region describes a strip        675pt tall  (= 874 − 116 − 83)
    ///     region.center sits at           y = 453.5   (= 116 + 675/2, NOT the view's 437)
    ///
    /// `MKMapView.region` describes the LAYOUT-MARGINS rect, not the view's bounds — the map
    /// draws edge to edge but reports the inset strip. That breaks both halves of the
    /// region-based rule at once, in the same direction:
    ///
    ///   * the lift is a fraction of SCREEN height (130.5/874 = 0.1493) but gets multiplied by a
    ///     span that only covers 675pt, so it moves 0.1493 × 675 = 100.8pt instead of 130.5 —
    ///     29.7pt short; and
    ///   * it starts from `region.center`, which is 16.5pt BELOW the view's centre.
    ///
    /// Total 46.2pt too low — measured, and exactly the "places the pin below where my crosshair
    /// is" report. (~115m at neighbourhood zoom, and it scales with zoom: the further out you are
    /// the further the pin misses.) It reads as zero for the first frame or two after launch,
    /// before the insets propagate, which is why it survives a quick look.
    ///
    /// Converting the crosshair's own screen point is exact by construction and carries no
    /// assumption about span, aspect ratio, layout margins or MapKit's zoom snapping.
    static func dropPoint(in mapView: MKMapView) -> CLLocationCoordinate2D {
        mapView.convert(crosshairPoint(in: mapView.bounds), toCoordinateFrom: mapView)
    }
}

/// A "heads up" line inside a control panel: a status-coloured glyph plus one sentence.
///
/// Exists because all three modes had grown their own version of this row — same shape, but each
/// with its own font, its own spacing and a raw `.orange`, so the same warning looked like a
/// different kind of thing depending on which tab you were on. Colour comes from the status, never
/// from a hue picked at the call site.
///
/// Usually built from a sentence — `WanderPanelNote(status:text:)`. The content-carrying
/// initialiser exists for the one advisory whose body is a LIVE view rather than a string (the
/// gs-loc cooldown countdown, which ticks); it gets the same glyph, the same status colour and the
/// same row rhythm, so a ticking note and a static one are the same object on screen.
struct WanderPanelNote<Content: View>: View {
    let status: Wander.Status
    /// Override the status's own glyph where a more specific one reads better (an hourglass for a
    /// cooldown, a raised hand for "not supported here"). Meaning still comes from `status`.
    var icon: String? = nil
    @ViewBuilder var content: () -> Content

    init(status: Wander.Status, icon: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.status = status
        self.icon = icon
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: MapModeChrome.groupSpacing) {
            Image(systemName: icon ?? status.symbol)
                .font(.wanderDetail)
                .foregroundStyle(status.color)
                // Redundant with the sentence for sighted users; VoiceOver would read the symbol
                // name before the actual words.
                .accessibilityHidden(true)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension WanderPanelNote where Content == AnyView {
    /// The common case: one sentence, styled by the token so no call site picks its own font.
    init(status: Wander.Status, text: String, icon: String? = nil) {
        self.init(status: status, icon: icon) {
            AnyView(
                Text(text)
                    .wanderDetail()
                    .fixedSize(horizontal: false, vertical: true)
            )
        }
    }
}

/// Fixed-height, top-aligned, internally scrolling. Deliberately NOT `hugScrollCard` — hugging is
/// what let the three modes disagree in their empty states, and it is why this type exists.
///
/// The internal scroll is also what makes the disclosure sections work without a taller panel: a
/// Joystick with hands-free open, or a Route with "More options" open, simply overflows this frame
/// and scrolls. Nothing gets its own height.
///
/// THE `fixedSize` IS LOAD-BEARING — do not delete it as redundant. A `ScrollView` proposes its own
/// (fixed) height to its content, and a `VStack` handed a height smaller than its ideal one does
/// NOT overflow: it COMPRESSES its flexible children to fit. Without the `fixedSize`, opening a
/// disclosure inside a panel squashed every `Text` in it to zero height and pushed the primary
/// button off the bottom — content silently disappeared instead of scrolling. Pinning the content
/// to its ideal height makes it rigid, so the excess overflows and the ScrollView does its job.
/// (`horizontal: false` so multi-line text still wraps to the panel's width and reports the taller
/// ideal height that wrapping implies.)
///
/// Verified on an iPhone 16: 30 natural-height rows in a panel render at full height and scroll,
/// with the panel's own frame — and therefore the crosshair — unmoved.
private struct WanderMapPanelSizing: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(height: MapModeChrome.panelHeight)
        .scrollBounceBehavior(.basedOnSize)
    }
}

extension View {

    /// Size a map mode's bottom control panel. THE ONLY sanctioned way to do it — a mode that
    /// reaches for a raw `.frame(height:)` or re-introduces a content-hugging wrapper has re-opened
    /// the drift this file closed.
    ///
    /// The height is a FLOOR as well as a cap: short content sits at the top of a panel that is
    /// still exactly `MapModeChrome.panelHeight` tall, and taller content scrolls inside it. That
    /// is the only way the three panels are the same size in EVERY state rather than only once
    /// they overflow — and the crosshair, which is derived from this one number, is only correct
    /// if the panel really is this tall.
    ///
    /// It takes NO parameters, on purpose. An `expanded:` flag used to live here and only two of
    /// the three modes could ever pass it, so the box still changed size when you switched tabs.
    func wanderMapPanel() -> some View {
        modifier(WanderMapPanelSizing())
    }

    /// The one elevation for anything floating over the map — the control panel and the map-style
    /// button draw the same shadow, so they read as sitting at the same height above it.
    func wanderMapShadow() -> some View {
        shadow(color: .black.opacity(MapModeChrome.shadowOpacity),
               radius: MapModeChrome.shadowRadius,
               y: MapModeChrome.shadowY)
    }

    /// Overlay the shared placement crosshair at the shared position.
    ///
    /// USE THIS, NOT A BARE `MapCrosshair()`, anywhere a full-bleed map has a control panel over
    /// its bottom — a bare centred crosshair is the exact rule this file replaced, and it aims at a
    /// point the panel is covering. Two screens still draw one by hand and are allowed to:
    /// `GeofenceEditorView` (a 240pt map inline in a Form, with nothing over it, so dead centre IS
    /// the centre) and `OfflineMapsSheet` (a sheet, so the tab bar and home indicator this file's
    /// `bottomChrome` assumes aren't there). Both say so at the call site. A THIRD one is drift.
    ///
    /// - Parameter isVisible: whether this mode is currently asking the user to place a point.
    func wanderMapCrosshair(_ isVisible: Bool) -> some View {
        overlay(alignment: .center) {
            if isVisible {
                MapCrosshair()
                    .offset(y: MapModeChrome.crosshairOffset)
                    .transition(.opacity)
            }
        }
        .animation(WanderMotion.quick, value: isVisible)
    }
}
