# Tandem

A macOS menu-bar app that shows MacBook and iPhone battery side by side, built
on top of the `BatteryCore` package (`../BatteryCore`, not modified by this
app).

## Build

The project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
Regenerate after editing `project.yml`:

```
cd TandemApp
xcodegen generate
```

Build (Xcode.app is required — `xcode-select` on this machine points at
CommandLineTools, which lacks the Swift 6 toolchain bits BatteryCore needs):

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project TandemApp/Tandem.xcodeproj -scheme Tandem -configuration Debug build
```

Build product: `Tandem.app` under
`~/Library/Developer/Xcode/DerivedData/Tandem-*/Build/Products/Debug/`.

The app is signed ad hoc (`CODE_SIGN_IDENTITY=-`, no team) and unsandboxed
(`ENABLE_APP_SANDBOX=NO`), because BatteryCore's phone half talks to usbmuxd
over `/var/run/usbmuxd`, which the App Sandbox blocks. Building still needs
the Homebrew kegs (`libimobiledevice`, `libusbmuxd`, `libimobiledevice-glue`,
`libplist`, `openssl@3` — plus `pkg-config`, see BatteryCore/NOTES.md §2), but
the *built* bundle no longer needs them: a post-build phase copies them into
`Contents/Frameworks`. See "Packaging" below.

## Run

```
open ~/Library/Developer/Xcode/DerivedData/Tandem-*/Build/Products/Debug/Tandem.app
```

`LSUIElement` is set, so there is no Dock icon; look for the menu-bar item
(two small glyph+percent pairs, e.g. a laptop icon and an iPhone icon each
with their charge). Click it to open the popover; clicking either device row
opens the summary window (below), scrolled/tabbed to that device. The
footer's `ellipsis.circle` menu on the right holds, top to bottom: "Summary…"
(opens the summary window with nothing highlighted), a "Summary layout"
submenu (a `Picker` between the two layouts, see "Summary window" below), a
divider, "Resync" — always offered, because a manual rediscovery is useful
long before the app is willing to call the phone silent; it calls
`monitor.resync()` (not just `requestRefresh()`: it also forgets the cached
address and rediscovers, see BatteryCore NOTES.md §16.1) — a divider, "Launch
at login" (reflecting
`SMAppService.mainApp`'s real status), a divider, and "Quit Tandem". There is
no Settings window — poll cadence, transport preference and the direct Wi-Fi
client are fixed defaults (see "What v1 does" below) — and no separate
Refresh button, since opening the popover already boosts polling and triggers
an immediate refresh, and the menu's "Resync" is always there.

**Age is never a fault.** There is no "Updated … ago" text anywhere in the
popover, and nothing dims because a reading is old: the phone is polled every
2–5 minutes at best and not at all while the display sleeps, so an old number
is the energy policy working (BatteryCore NOTES.md §14). A row only dims to
45 %, and an iPhone only swaps its charging bolt for an orange
`exclamationmark.circle.fill`, once `DeviceStatus.isSilent(now:)` is true —
**we have been failing to read it for over ten minutes, across at least two
attempts** (NOTES.md §14.8). The glyph's tooltip still says when the phone was
last seen and how long ago that was, plus the last error if there is one.

Quit via the footer menu's "Quit Tandem", `osascript -e 'quit app "Tandem"'`,
or `pkill -x Tandem`.

## Where the snapshot lives

Two copies of the same file, both written after every poll (and on manual
refresh), both pretty-printed, key-sorted JSON with ISO-8601 dates:

1. `~/Library/Application Support/Tandem/snapshot.json` — written by
   `BatteryCore.SnapshotStore` from inside `TandemMonitor`, as before. This is
   the canonical one; `tandemctl` and anything else unsandboxed reads it.
2. `~/Library/Containers/dev.tandem.app.widget/Data/Documents/snapshot.json` —
   written by `WidgetBridge` for the widget extension. See below for why it is
   in such an odd place.

A third file, `history-summary.json`, is written next to both copies (see
"Summary window" and "Widget" below) at most every ten minutes
(`HistoryStore.writeSummary`, NOTES.md §15.4) — it is the only source for the
24 h chart, in both the summary window and the large widget.

## Summary window

`tandem://summary` opens a non-resizable `Window` scene (`SummaryWindowView`)
with both devices' recorded history — battery health, last charge session,
today's stats and the 24 h chart card, from `TandemModel.history` (the app's own
`HistoryStore`, reloaded every 60 s while the window is open) plus the live
snapshot for the header numbers. Three entry points reach it, all through
`TandemModel.requestSummary(device:)`: a popover row (that device
highlighted), the footer menu's "Summary…" (nothing highlighted), and a widget
tile tap, which arrives as the URL `tandem://summary[/mac|/iphone]` handled by
`AppDelegate.application(_:open:)`.

Two layouts, picked from the footer's "Summary layout" submenu and remembered
in `@AppStorage("summaryLayout")` (`SummaryLayout`, `SummaryWindow.swift`):

- **Two columns** (`SummaryColumnsView`, 924×780) — both devices side by side.
- **Tabs** (`SummaryTabsView`, 480×780) — one device at a time behind a tab
  bar.

Both grew from 640 pt tall when the 24 h card became two plots
(`SummaryChartCard`); nothing above the card moved.

The window resizes to the chosen layout's fixed size; `defaultSize` in
`TandemApp.swift` and the `WindowConfigurator`'s explicit `setContentSize` both
follow `SummaryLayout.size`.

### The 24 h card

One card, two plots, one shared time axis (`SummaryChartCard` in
`SummaryDesign.swift`; the approved design is `docs/design/chart/ChartB2.dc.html`):

- **Charge · 24 hours** — one `BarMark` per half-hour bin of
  `DeviceHistory.bins24h` (48 of them, the last ending at *now*), coloured by
  what the device was doing for most of that half hour: green on the battery,
  amber charging, blue plugged in and holding. The newest bar is at full
  opacity and the rest at 0.85, the grid is a solid hairline at 0 / 50 / 100
  with the numbers on the **left**, and a dashed rule marks 80 %. No time
  labels here.
- **Power** — `powerInW` per bin as a bar (amber while charging, a thin blue
  one while the adapter is merely carrying the machine, nothing at all on
  battery) under the purple `systemLoadW` line, on a y axis that runs to a
  round ceiling above whichever of the two is taller. The **time labels live
  here only**: whole clock hours six apart, counted back from now.

Colour in these two plots means *state*, never level — the one place in the app
where it does not follow the green/red-below-20 % rule. An iPhone cannot produce the `mains`
state and needs no separate path. With fewer than two bins carrying a percent
the card draws its axes and one line, "Collecting history…".

**Item 1a — a tile tap while the window is already open does not re-open or
reposition it.** `SummaryWindowView.isOnScreen` checks `NSApp.windows` before
`requestSummary` records the request; when the window is already visible, the
new `SummaryRequest` carries `raisesWindow == false` and `WindowConfigurator`
skips activation, `orderFront` and recentring entirely — only the selection
changes (the highlighted column in "Two columns", the selected tab in "Tabs").
A request that does need the window shown (`raisesWindow == true`) also
recentres it if its remembered frame has drifted off every current screen
(unplugged display, or a layout change past the remaining screen's edge).

## Widget

`TandemWidget.appex` (bundle id `dev.tandem.app.widget`) is a WidgetKit
extension embedded in `Tandem.app/Contents/PlugIns/`. It offers three families
(`.supportedFamilies([.systemSmall, .systemMedium, .systemLarge])`,
`TandemWidgetBundle.swift`):

- **Small** — two concentric rings (Mac outside, iPhone inside), an orange
  `bolt.fill` in the middle whenever *either* device is charging, and two
  columns underneath: `laptopcomputer` + percent + time on the left,
  `iphone` + percent + time on the right.
- **Medium** — two tiles either side of a hairline, modelled on the system
  Batteries widget and 14 pt inside the widget edge (`MediumWidgetView`, which
  cancels WidgetKit's own content margins to get there). Three bands
  (`DeviceTile`, design `docs/design/widget/MediumA.dc.html`): a 52 pt ring,
  stroke 6, device glyph at 22 pt, with one 15 pt line beside it; then the
  device's last 24 hours as twelve two-hour columns across the tile's whole
  width (`DayBarsView`, 36 pt tall, 2 pt gaps); then the percent at 30 pt
  semibold tabular with one 12.5 pt status baseline-aligned to its right. An
  orange badge rides the ring's top-right: `bolt.fill` while charging,
  `exclamationmark` when the device has gone quiet — never both.
- **Large** (`LargeWidgetView`) — the medium family's two tiles verbatim across
  the top, then one card below with both devices' last 24 hours on the same
  axes as the summary window's chart (last 24 h ending at *now*, values on the
  left, whole clock hours six apart), each device its own line/colour with a
  legend, plus one line per device that had a charge in the window. Its only
  data source is `history-summary.json` (see "Where the snapshot lives"
  above); when that file is missing or older than
  `HistorySummary.freshnessWindow` (2 hours — the app writes it at most every
  ten minutes, so that means the app has not run in a while) the card draws
  its axes with nothing plotted rather than stale data pretending to be
  current.

The tile's two text slots are one state matrix, and every state fills both of
them (`docs/design/widget/StatesMac.dc.html`, `StatesPhone.dc.html`;
`DevicePresentation` decides, `DeviceTile` draws):

| state | beside the ring | bottom right |
| --- | --- | --- |
| charging | `62/140 W`, amber semibold | `80 % · 27 min` (`80 % · —` before the estimator has an ETA, `charged` once past 80 %) |
| on battery | `−13 W` on the Mac, `on battery` on the phone, both secondary | `4:19` |
| plugged in, not charging | `powerplug` glyph + `13/140 W` in blue semibold (an iPhone left on the wire past 100 % reads `45 W`) | `charged` at/above 80 % or full, else `on hold` |
| silent (failing for > 10 min, ≥ 2 attempts) | `silent since 14:32` | `14:32` |
| never seen | `no data` | *(nothing)* |

The watts are always the honest "in / available" pair and never a measurement of
nothing: a phone's discharge wattage is deliberately not published, and a Mac
whose reading came back partial says `on battery` rather than `0 W`.

Ring colour is a function of level only — **green, and red below 20 %**. Two
bands, not three: orange belongs to charging (the bolt, the watts, the amber
columns of the day strip), and a ring that turned orange at 49 % read as
"plugged in" when it was not. The same rule is `batteryLevelColor`
(`StatColumns.swift`) for the popover bars and `summaryLevelColor`
(`SummaryDesign.swift`) for the summary rings.

A **silent** device — one we have been trying and failing to read for over ten
minutes, over at least two attempts (`DeviceStatus.isSilent(now:)`, the same
rule the popover row uses) — is drawn at 45 % opacity *except* for its
exclamation badge, which is the one mark on the widget whose job is to be
noticed. The clock in `silent since 14:32` is `unreachableSince`, the moment
the failures started, not `lastSeen`: a stale reading on its own never dims
anything, because the phone is deliberately polled every 2–5 minutes and not at
all while the display sleeps (NOTES.md §14.8). A device that has never been seen
has no level at all: the percent is an em dash and the ring is drawn as a bare
track, never `0 %` with a dot of red.
`min`, `charged`, `on hold`, `on battery`, `no data` and `silent since %@`
are the translated tokens (`Sources/TandemWidget/Localizable.xcstrings`,
en + ru); everything else on the widget is a number.

The day strip's twelve columns are `DeviceHistory.bins24h` folded four half
hours at a time (`DayBars.fold`): each column takes the last level known inside
its two hours and the state those two hours spent most of their time in, which
at equal bin widths is a plain majority of the four with a tie going to the
newest. Green on the pack, amber charging, blue on the wall and holding — the
summary window's own three colours by number
(`BarPalette`/`SummaryPalette`) rather than system colours, because three states
have to stay apart at 10 pt wide. The newest column is drawn at full strength
and the rest at 70 %; a column with no reading at all is a 2 pt stub. With no
`history-summary.json`, or one older than `HistorySummary.freshnessWindow`, the
strip is an empty track instead — the same test the large family's chart makes.
The medium family folds the file once per timeline and copies twelve columns
per device into its fifteen pre-rendered entries, rather than fifteen copies of
the whole summary.

`docs/widget-small.png`, `docs/widget-small-charging.png`,
`docs/widget-medium.png`, `docs/widget-medium-charging.png`,
`docs/widget-medium-states.png` (the four combinations from
`docs/design/widget/Combos.dc.html`, rendered from the real view) and
`docs/widget-large.png` are rendered from these very sources by
`tools/render-widget.swift` (the header comment has the `swiftc` line). They
show the widget *content* only — the translucent material a placed widget
sits on comes from the widget host and no offscreen renderer can produce it.

### Background: a material, not a fill

`TandemWidgetEntryView` ends in `.containerBackground(.regularMaterial, for:
.widget)`, and the material is load-bearing. A macOS desktop widget has two
looks. While an app window is in front the host desaturates every widget and
substitutes its own translucent material, and nothing put in the container
background makes any difference. The moment the desktop is revealed — which is
when anyone actually looks at their widgets — the host hands each widget its
own colours *and its own background*, and only then does this modifier show.

Sampled from single ScreenCaptureKit frames containing only the wallpaper and
the desktop widget windows (which composites the material properly and reaches
widgets an app window is covering), across the width of each widget:

| container background | this widget, desktop revealed | Batteries, same frame | Calendar, same frame |
| --- | --- | --- | --- |
| `.fill.tertiary` (Xcode's template default) | `#0D0D0D`, flat | `#4F4F54` → `#2B2D33` | `#515151` → `#3C3D3C` |
| `Color.clear` | `#222221`, flat | as above | as above |

The system widgets' backgrounds *vary* across their own width: they are
translucent over the wallpaper. Ours did not vary — it was an opaque near-black
plate, which is exactly what the bug report described. Neither a transparent
background nor a hierarchical fill has anything to be translucent against, so
both land on the black the host leaves behind; a `Material` is the one SwiftUI
background that samples what is behind it.

Note also that a placed widget keeps rendering the archive produced by the
*running* appex process: rebuilding and relaunching the app is not enough to
see a code change on the desktop, `pkill -f TandemWidget.appex` is (chronod
relaunches it on the next reload).

Data comes from the same `TandemSnapshot` the app writes. The widget target
compiles `Models.swift`, `TandemSnapshot.swift`, `Formatting.swift` and
`ChargeEstimator.swift` straight out of `../BatteryCore/Sources/BatteryCore`
(see `project.yml`) rather than linking the `BatteryCore` product, so the type
is literally the same source and not a hand-copied twin — but without dragging
in the libimobiledevice/openssl chain, which a sandboxed extension cannot load
from `/opt/homebrew`. The one BatteryCore type that could not come along is
`MonitorError` (its file reaches into `PhoneError` / `DirectLockdownError`);
`Sources/TandemWidget/MonitorErrorShim.swift` stands in for it with a
decode-compatible struct that `DeviceStatus` never renders.

Timeline: **one entry a minute for the next fifteen minutes**, policy
`.after(now + 15 min)`. All fifteen are built from the same snapshot — the
countdown to 80 %, the silence dimming and the `· 12 min` age are all
computed from the entry's own date against absolute times in the snapshot
(`DeviceStatus.etaTo80At`, `unreachableSince`), so the widget ticks for a quarter of an
hour without anything polling the phone. Each `getTimeline` also drops the
visibility breadcrumb described under "Energy policy" below.

The app calls `WidgetCenter.shared.reloadAllTimelines()` after a snapshot
write, gated twice: at most once per 30 s (`WidgetBridge.reloadThrottle`) *and*
only when `WidgetBridge.materiallyChanged(from:to:)` says the widget would draw
something different — percent, charging/plugged/full state, a watt or more of
power (`wattTolerance`), adapter watts, or a device appearing or disappearing.

The extension carries its own `Assets.xcassets` with a byte-identical copy of
the app's `AppIcon.appiconset`, plus a `WidgetBackground` colour set. The
gallery's sidebar takes its icon from the *extension* bundle rather than from
the containing app, so without that copy the row is the generic placeholder
plug. Both are named twice — once as a build setting in `project.yml`
(`ASSETCATALOG_COMPILER_APPICON_NAME`,
`ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME`) and once in
`Sources/TandemWidget/Info.plist` (`CFBundleIconName` / `CFBundleIconFile`,
`NSWidgetBackgroundColorName`), because `GENERATE_INFOPLIST_FILE` is off for
this target and nothing would inject the keys otherwise. Every Apple widget
extension on the system declares `NSWidgetBackgroundColorName` — Batteries and
Weather as `WidgetBackground`, Calendar and Notes as `WidgetBackgroundColor`.

### The container-path trick (no signing identity, so no App Group)

`security find-identity -v -p codesigning` returns **zero** identities on this
machine. No identity means no team, no team means an App Group entitlement
cannot be issued — so the normal way an app and its widget share a file is
simply unavailable here.

The workaround (the same one AirBattery uses) inverts the relationship:

- The **widget** is sandboxed (`Sources/TandemWidget/TandemWidget.entitlements`
  sets `com.apple.security.app-sandbox`), so it gets a container of its own and
  its `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)`
  resolves to
  `~/Library/Containers/dev.tandem.app.widget/Data/Documents`.
- The **app** is *not* sandboxed (it has to talk to `/var/run/usbmuxd`), so it
  can write straight into that directory. `WidgetBridge` does exactly that,
  creating intermediate directories if the container has not been made yet.

Nothing in the extension knows the file arrived from outside — it just reads
its own Documents folder. Both processes are ad-hoc signed
(`CODE_SIGN_IDENTITY = "-"`).

To confirm the path the widget really sees, the extension logs it once per
launch:

```
log show --predicate 'subsystem == "dev.tandem"' --last 5m
```

You should see `widget documents dir: …/Containers/dev.tandem.app.widget/Data/Documents/snapshot.json`
followed by `read snapshot from …`. Nothing is logged until the widget has
actually been placed somewhere — a registered-but-unplaced widget extension is
never launched.

### Adding the widget

1. Build, then launch the app once so the system registers the extension:

   ```
   open ~/Library/Developer/Xcode/DerivedData/Tandem-*/Build/Products/Debug/Tandem.app
   pluginkit -m -p com.apple.widgetkit-extension | grep -i tandem
   ```

   Registration is what the second line proves; it should print
   `dev.tandem.app.widget(1.0)`.

2. Right-click an empty spot on the desktop → **Edit Widgets** (or open
   Notification Center by clicking the menu-bar clock and press **Edit
   Widgets** at the bottom). Pick **Tandem** in the left-hand list, then drag
   **Tandem Battery** — small or medium — onto the desktop or into
   Notification Center.

Adding a widget is drag-and-drop into a system-owned gallery; there is no
scriptable API and no AppleScript-visible target for it, so this step cannot be
automated and has to be done by hand.

### Limitations without a signing identity

- **No App Group.** Hence the container trick above. If a Developer ID or even
  a free personal team ever becomes available, the right fix is one App Group
  shared by both targets and a single `SnapshotStore` pointed at it; the second
  write in `WidgetBridge` then goes away.
- **Ad-hoc signature.** The `.app` and the `.appex` are signed `-`. That is
  fine locally, but the bundle is not notarised and not transferable — on
  another Mac Gatekeeper will refuse it, and the widget would not register at
  all.
- **The appex only registers from wherever it was launched.** `pluginkit`
  records the DerivedData path; move or rebuild the app elsewhere and you need
  to launch it again from the new location.
- **No configuration intent.** `StaticConfiguration`, so the widget has no
  "choose a device" editing UI. With no team there is no App Intents
  entitlement story worth building against yet.

## What v1 does

- `MenuBarExtra` (`.window` style) status item: laptop + Mac % and iPhone +
  iPhone %, with a small bolt after a charging device, `iphone.slash` when
  the phone has never been seen.
- Popover: one row per device (Mac then iPhone) — icon, name, right-aligned
  percent, a thin progress bar (green / amber-while-charging / red
  below 15%), and three telemetry columns: **system** (what the
  machine is drawing — `PowerTelemetryData.SystemLoad`, `13 W` plugged in,
  `−13 W` on battery, blank for an iPhone on battery), **adapter**
  (`13/140 W` — `SystemPowerIn` over `AdapterDetails.Watts`, with the orange
  bolt only while actually charging, an em dash on battery), and
  **time** (ETA-to-80% while charging, time-left otherwise). The system column
  is why a plugged-in Mac no longer reads "0 W": battery current is 0 there
  and says nothing about consumption (NOTES.md §6, §9). A partial (degraded-tier) or aging-detail phone reading
  (`DeviceStatus.detailAge` set and > 120 s) dims just those three columns to
  55% opacity — silently, no text (NOTES.md §13.2). A **silent** row (any
  device: `DeviceStatus.isSilent(now:)` — failing for over ten minutes across
  at least two attempts) dims to 45% opacity, also silently; an old reading on
  its own never dims anything, because polling is deliberately sparse
  (NOTES.md §14.8). Freshness never gets a text line: an iPhone that is silent
  by that rule (or that has never been seen) instead swaps its header bolt for an orange
  `exclamationmark.circle.fill`, with `.help()` showing
  `phoneError.localizedKey` (looked up in the String Catalog) when there is
  one; a phone that has never been seen at all still falls back to the
  "iPhone not reachable" row plus that same error text. Each row is also a
  button that opens the summary window at that device (`.help()` shows
  "Summary…"). Opening the popover calls `monitor.setActivity(.popoverOpen)`
  (15 s cadence, self-clearing after 2 minutes) and `monitor.requestRefresh()`
  once for an immediate reading; closing it drops back to the ambient level
  from `onDisappear`. The rows sit in a `TimelineView(.periodic(by: 60))`, so
  the "to 80 %" column counts down once a minute off `DeviceStatus.etaTo80At`
  — an absolute deadline — and reads `charged` once it is passed, with no
  polling behind it. Footer: a small borderless `ellipsis.circle` menu,
  right-aligned — "Summary…" (opens the summary window with nothing
  highlighted), a "Summary layout" submenu (picker between the two layouts,
  see "Summary window" above), a divider, "Resync" (always shown — a manual
  rediscovery is useful long before the silence rule fires; calls
  `monitor.resync()`, which forgets the
  cached address, drops any kept-alive session and rediscovers before reading
  — BatteryCore NOTES.md §16.1 — not just a fresh poll), a divider, "Launch at
  login" (bound live to `SMAppService.mainApp.status == .enabled`), a
  divider, "Quit Tandem".
- No Settings window. The polling cadence is no longer a fixed pair of
  numbers at all — see "Energy policy" below — while transport preference (USB
  over Wi-Fi) and the direct Wi-Fi client (on) stay baked-in defaults in
  `TandemModel.init` — they were never actually
  configurable in a way that mattered, per user feedback. Launch-at-login is
  the one setting that survived: the app registers with `SMAppService.mainApp`
  once, automatically, on first launch (`TandemApp`, tracked by the
  `didRegisterLoginItem` `@AppStorage` flag so it's never re-attempted), and
  after that the footer menu's toggle is the only way to change it, reading
  and writing `SMAppService.mainApp` directly rather than caching state.
- One `@MainActor @Observable TandemModel` owns the monitor, consumes
  `monitor.snapshots()`, writes each snapshot via `SnapshotStore`, and drives
  the activity level from the six notifications listed under "Energy policy".
- String Catalog (`Sources/Tandem/Localizable.xcstrings`) with English base
  and Russian translations for the fixed UI chrome (menu items, row/footer
  status text). See "Localization scope" below for what is deliberately
  *not* in the catalog.

## Energy policy

The phone poll is the expensive one (a TLS handshake that wakes the phone's
radio); the Mac read is a free in-process IOKit call. So how often the phone is
dialled now depends on whether anybody can see the answer —
`BatteryCore.ActivityLevel`, `TandemMonitor.setActivity(_:)`, and NOTES.md §14
for the whole design.

| level | phone, charging | phone, on battery | set by |
| --- | --- | --- | --- |
| `.hidden` | never | never | display asleep, system sleep, or screen locked |
| `.background` | 120 s | 300 s | the default: menu-bar label only |
| `.widgetVisible` | 60 s | 120 s | a widget asked for a timeline in the last 10 min |
| `.popoverOpen` | 15 s | 15 s | popover open (clears itself after 2 min) |

`TandemModel` tracks three flags — display asleep, screen locked, popover open
— and recomputes the level from all six notifications that move them:
`NSWorkspace`'s `screensDidSleep` / `screensDidWake` / `willSleep` / `didWake`,
and `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` from
`DistributedNotificationCenter` (a locked Mac with the display awake is showing
nothing either). `.hidden` beats everything: the phone loop then does not
discover, connect or read at all until the screen is back, while the Mac keeps
its event-driven reads plus a 10-minute sanity read. Raising the level polls
immediately; lowering it costs nothing.

**Widget visibility** cannot be asked for, only inferred: WidgetKit runs a
timeline provider only for a widget somebody has actually placed. The extension
therefore writes
`~/Library/Containers/dev.tandem.app.widget/Data/Documents/widget-activity.json`
(`{"family":"medium","requestedAt":"…"}`) on every timeline request — the same
container trick as `snapshot.json`, in the other direction — and the app reads
it on every scheduling decision (`WidgetActivityProbe`, cached 15 s), raising
`.background` to `.widgetVisible` while it is under 10 minutes old.

Two more things stopped being per-poll work: the menu-bar label is rasterised
only when `MenuBarLabelState` (two percents, two charging flags) changes rather
than on every snapshot, and the widget reload is gated on a material change as
described under "Widget" above.

What it costs: an unplug that happens while the screen is locked is not noticed
until the screen comes back, and a background reading can be five minutes old
when the popover opens — for the one read it takes to refresh it.

`tandemctl watch --stats` prints the counters (attempted/succeeded by level)
once a minute; the app logs the same line hourly under subsystem `dev.tandem`,
category `energy`:

```
log show --predicate 'subsystem == "dev.tandem" && category == "energy"' --last 3h
```

## Notifications

One notification, driven entirely by `BatteryCore.ChargeMilestone` (a pure
state machine over the snapshot stream — no UI, no clock of its own, see
NOTES.md §16.2): "MacBook reached 80 %" / "iPhone reached 80 %", fired once per
charging session, the moment either device crosses from below 80 % to 80 % or
above while charging. `TandemModel` feeds every snapshot into one
`ChargeMilestone` per device and hands whatever event comes back to
`ChargeNotifier`, which asks for provisional authorization the first time it
has something to post (`.alert, .sound, .provisional` — no prompt, delivered
quietly to Notification Center; macOS promotes it to a full grant the first
time the user keeps one) and then posts a `UNNotificationRequest` with the
device name, elapsed charging time and watts, where known. Tapping the banner
opens the summary window at that device through the same `tandem://summary/
<device>` URL a widget tile uses (`AppDelegate.handle(_:)`), so the
already-open-window rule (item 1a) applies to a notification tap exactly as it
does to a tile tap. A second crossing for the same device before the first
notification is dismissed replaces it (one identifier per device) rather than
stacking.

```
log show --predicate 'subsystem == "dev.tandem" && category == "notify"' --last 1h
```

## A real bug found and fixed along the way

The first `MenuBarLabelView` was a plain `HStack` of `Image`/`Text` (mac
icon, mac %, iPhone icon, iPhone %, optional bolt). It built and looked
correct in code review, but on the real device only the *first* icon+percent
pair ever appeared in the actual menu bar — the iPhone half silently vanished
regardless of a fixed `.frame(width:)` or `.fixedSize()`, and regardless of
whether the phone was reachable or not. Concatenating everything into one
`Text` (`Text(Image(systemName:)) + Text("...")...`) didn't fix it either:
Accessibility Inspector-equivalent (`System Events`) showed the placeholder
characters for the images were present in the title string, but no pixels
were ever painted for them. Both point at the same root cause:
`MenuBarExtra`'s label gets flattened into a single `NSStatusBarButton`
title/image, and that path doesn't reliably paint more than one inline image
attachment.

The fix (`MenuBarLabelView.swift`) rasterizes the label with `ImageRenderer`
into an `NSImage` marked `.isTemplate`, and shows that as a plain `Image`.
This is verified working on-device (screenshot below) with both chips, the
percent text, and the charging bolt all visible and auto-tinted for the menu
bar. It's more machinery than the "obvious" SwiftUI code, but it's the
reliable pattern for composite `MenuBarExtra` labels.

## Localization scope

Freshness/relative-time text was removed from the UI entirely (see "Run"
above) — there is no longer any `RelativeDateTimeFormatter` use in the app —
and every sentence-level piece of UI chrome (menu items including "Summary…"
and "Summary layout", the layout names "Two columns"/"Tabs", "not reachable"
messages, the 80 % notification title and body) is in the String Catalog with
English + Russian. Numeric telemetry stays numeric — percent, watts (plain
`String(format:)`, no unit word to translate) and `4:19`-style clock durations
(`StatusFormatter.clockDuration`, pure digits) render identically in every
language. `11 h 36 min`-style durations
(`StatusFormatter.shortDuration`/`compactAge`) are the one place a unit word
does travel: `BatteryCore.DurationUnits.current` resolves `h`/`min` vs.
`ч`/`мин` once from the host bundle's `preferredLocalizations`, so a duration
translates without needing a full sentence template in the catalog for every
possible number. `tandemctl`'s own `StatusFormatter.line` opts out on purpose
(`.english` units, hard-coded English words like "charging"/"stale") since it
is a diagnostic line meant to be pasted into notes and issues verbatim,
whatever the host's language.

## Packaging

`Tandem.app` used to link `libimobiledevice-1.0`, `libusbmuxd-2.0`,
`libimobiledevice-glue-1.0`, `libplist-2.0`, `libssl.3` and `libcrypto.3`
straight out of `/opt/homebrew`, so it only ran on a Mac with the same kegs
installed at the same absolute paths. `tools/bundle-dylibs.sh` fixes that, and
the Tandem target runs it as a post-build phase (`postBuildScripts` in
`project.yml`, `basedOnDependencyAnalysis: false` so it runs on every build).
It is idempotent — a second run re-copies from the pristine Homebrew originals
and produces byte-identical output — and it fails the build loudly if any
dylib in the closure is missing.

What the script does, in order:

1. Walks the **closure** of non-system dylibs reachable from every Mach-O in
   `Contents/MacOS`. In Debug that is three binaries (`Tandem`, Xcode's
   `Tandem.debug.dylib`, `__preview.dylib`); in Release just `Tandem`. It
   follows `otool -L` transitively, so `libimobiledevice-glue` gets picked up
   even though nothing links it directly, and it resolves symlinks — `libssl`
   names `libcrypto` by its `Cellar/openssl@3/3.6.3` path while everyone else
   names it by the `opt/openssl@3` path, and both have to land on one copy.
2. Copies each into `Contents/Frameworks`, sets `LC_ID_DYLIB` to
   `@rpath/<name>` and rewrites every dependent reference the same way, in the
   copies *and* in the app's own binaries.
3. Deletes a stale `/opt/homebrew/lib` `LC_RPATH` if an older build left one,
   and makes sure `@executable_path/../Frameworks` is present.
   `LD_RUNPATH_SEARCH_PATHS` in `project.yml` no longer lists `/opt/homebrew/lib`
   at all — leaving it in would hide a bundling failure on this machine while
   still failing on every other one.
4. Copies the upstream licence texts out of the very keg each dylib came from
   into `Contents/Resources/Licenses/<formula>/` (LGPL-2.1 `COPYING` +
   `COPYING.LESSER` for libimobiledevice / libusbmuxd / libimobiledevice-glue /
   libplist, Apache-2.0 `LICENSE.txt` for OpenSSL 3), plus a `README.txt`
   mapping each dylib to its formula, version and licence files.
5. Ad-hoc re-signs (`codesign --force --sign - --timestamp=none`) every dylib
   it touched, then the `Contents/MacOS/*.dylib` Xcode debug/preview dylibs
   (they are sealed as *resources* of the app, so the app's own signing step
   does not cover them), then the app bundle.
6. Verifies: no Mach-O anywhere under `Contents/` still names an `/opt/…`
   library or carries an `/opt/…` runpath. This also covers
   `TandemWidget.appex`, which must stay Homebrew-free — it is sandboxed and
   deliberately compiles the four Foundation-only BatteryCore files instead of
   linking the package.

Deliberately **not** `codesign --deep` on the app: `TandemWidget.appex` carries
its own sandbox entitlements, and a deep re-sign would drop them and break the
container trick the widget's snapshot delivery depends on. Nested code is
signed individually and the app's signature then seals it by cdhash. Xcode's
own `CodeSign` step runs after this phase and re-signs the app bundle over the
top; the dylibs keep the signatures the script gave them.

Verification on the current build:

```
$ otool -L Tandem.app/Contents/MacOS/Tandem.debug.dylib | grep -v /usr/lib/ | grep -v /System/
        @rpath/libssl.3.dylib
        @rpath/libcrypto.3.dylib
        @rpath/libimobiledevice-1.0.6.dylib
        @rpath/libplist-2.0.4.dylib
        @rpath/libusbmuxd-2.0.7.dylib

$ DYLD_PRINT_LIBRARIES=1 Tandem.app/Contents/MacOS/Tandem 2>&1 | grep -c homebrew
0
```

All six dylibs load from `Tandem.app/Contents/Frameworks/`, and
`codesign --verify --deep --strict` passes.

### Open issues

- **Ad-hoc only.** There is no signing identity on this machine
  (`security find-identity -v -p codesigning` is empty), so the bundle is
  signed `-` and is not notarised — Gatekeeper will still refuse it on someone
  else's Mac. Self-containment and distributability are separate problems; this
  solves the first one.
- **A Developer ID build needs more.** Hardened Runtime is off
  (`ENABLE_HARDENED_RUNTIME=NO`); turning it on for notarisation means every
  bundled dylib must be signed with the same Developer ID *and* with the
  hardened runtime flag, and they must be signed inside-out before the app.
  The script's `codesign` invocation would then need `--options runtime` and
  the real identity (it already honours a `CODESIGN` override, so the identity
  is the only new input). Notarisation also rejects unsigned nested code, so
  the ordering in step 5 stays as it is.
- **The Homebrew bottles target macOS 26** while the app deploys to 15.0 — the
  familiar `ld: warning: … built for newer version 26.0` (NOTES.md §2). Bundling
  copies that mismatch into the app rather than fixing it; a genuinely portable
  build would compile the chain from source with `MACOSX_DEPLOYMENT_TARGET=15.0`.
- **A dev-only rpath survives in Debug.** Xcode adds an absolute
  `…/DerivedData/…/PackageFrameworks` `LC_RPATH` for the SwiftPM dependency.
  It points at an empty directory and nothing resolves through it, so the
  script leaves it alone. A Release build does not get it — verified: the
  Release `Tandem` binary's only runpaths are `/usr/lib/swift` and
  `@executable_path/../Frameworks`.
- The script assumes one library per basename. Two dependencies with the same
  file name would collide in `Contents/Frameworks`; it detects that and fails
  rather than silently shipping one of them.

## Stubbed / not done

- **No app icon** (not needed — `LSUIElement`).
- **No Settings window.** Removed after user feedback that it "gave nothing" —
  the four toggles/pickers it held are now fixed defaults baked into
  `TandemModel.init` (see "What v1 does"). If per-user tuning of poll cadence
  or transport ever becomes a real need, the right fix is a lightweight
  popover-attached menu rather than reintroducing a separate window.
- **The widget cannot be added by script.** The extension is built, embedded,
  ad-hoc signed and registered (`pluginkit` sees it), but placing it on the
  desktop or in Notification Center is a drag into a system gallery with no
  automatable entry point. `docs/widget-*.png` are therefore renders of the
  widget's own SwiftUI views at exact widget point sizes, not captures of the
  live gallery — see "Acceptance evidence".
- The literal brief text said to "start `monitor.run()` in a Task and
  consume `monitor.snapshots()`". `TandemMonitor.snapshots()`'s own doc
  comment says iterating it already starts (and, on cancellation, stops) the
  polling loops. Calling `run()` as well would start a second, redundant
  pair of poll loops. `TandemModel` only consumes `snapshots()` — see the
  comment on `TandemModel` for the reasoning.

## BatteryCore APIs I wished existed

All four of these landed in BatteryCore §13.5 and are wired into the app now;
kept here (struck through) as a record of what was missing before.

- ~~**Live reconfiguration of a running `TandemMonitor`** — a setter for
  `PollingPolicy` / `preferNetworkTransport` / `keepPhoneSessionAlive`
  instead of only being able to set them at `init`. Would let Settings
  changes apply without dropping monitor state.~~ `TandemMonitor.update(configuration:)`
  / `setPolicy` / `setPreferNetworkTransport` / `setUseDirectClient` do
  exactly this in place; no longer exercised by the app itself now that
  polling/transport are fixed at `TandemModel.init` rather than
  user-configurable (`Sources/Tandem/TandemModel.swift`), but the API is
  still there for whoever needs it next.
- **A published "reachability changed" or "phone first seen" signal**
  distinct from a full snapshot, so the UI could animate/notify on the
  transition instead of diffing `TandemSnapshot`s itself. Still open.
- ~~**A typed error enum surfaced through `TandemMonitor`**~~ `MonitorError`
  now travels inside `TandemSnapshot` (`phoneError`/`macError`) with a stable
  `localizedKey` per case; the popover looks that key up in the String
  Catalog instead of showing the old `String(describing:)` blob
  (`Sources/Tandem/DeviceRowView.swift`).
- ~~**Keep-alive-while-popover-is-open convenience**~~ `TandemMonitor.setActivity(_:)`
  does this and more: `.popoverOpen` is the 15 s cadence for up to two minutes,
  and the other three levels are the energy policy above
  (`Sources/Tandem/PopoverContentView.swift`, `Sources/Tandem/TandemModel.swift`).
  `setBoosted(_:)` is still there as a shim.

## Acceptance evidence

- Build: `xcodebuild ... build` → **BUILD SUCCEEDED** on the first attempt
  after the project was generated.
- `docs/menubar.png` — the status-item label (`MenuBarArtwork`) at 2x, and
  `docs/popover.png` — the popover's two `DeviceRowView`s, its divider and its
  overflow control at the real 300 pt width. Both come out of
  `tools/render-popover.swift`, which drives the app's own views through
  `ImageRenderer` with synthetic devices. The earlier pair were live captures
  of a desktop; they were replaced so the repository ships no picture of
  anybody's machine.
- `~/Library/Application Support/Tandem/snapshot.json` exists and updates
  every poll; see the phone excerpt in the task report.
- `ls Tandem.app/Contents/PlugIns` → `TandemWidget.appex`.
- `pluginkit -m -p com.apple.widgetkit-extension | grep -i tandem` →
  `dev.tandem.app.widget(1.0)`.
- `docs/widget-small.png`, `docs/widget-medium.png`, `docs/widget-large.png`
  — all three families with the live snapshot, and
  `docs/widget-small-charging.png`, `docs/widget-medium-charging.png`
  with the 71 % / 64 % gallery placeholder, so the charging path (bolt, orange
  watts, `80 % · 14 min`) is visible too. These are produced by running
  `SmallWidgetView` / `MediumWidgetView` / `LargeWidgetView` — the widget's
  real view code, real snapshot decoding — through `ImageRenderer` at their
  exact widget point sizes with the widget's own content margins. A capture of
  the live gallery would have needed a drag-and-drop the accessibility API
  does not expose.
- `docs/summary-columns.png`, `docs/summary-columns-empty.png`,
  `docs/summary-tabs.png` — the summary window in both layouts, produced by
  `tools/render-summary.swift` the same way, from synthetic history data.

## Release

`tools/make-dmg.sh` turns a checkout into `dist/Tandem-<version>.dmg`. It is
the whole release procedure — there is no other step, and nothing about it is
hand-done.

```
tools/make-dmg.sh [version] [--strict] [--no-launch]
```

- **version** — defaults to `MARKETING_VERSION` in `TandemApp/project.yml`
  (currently `1.0`). Pass one explicitly only to cut a differently-numbered
  build from the same source.
- **`--strict`** — refuse to run on a dirty git tree. Use it for a real
  release; without it a dirty tree is only a warning, so the script stays
  usable mid-development.
- **`--no-launch`** — skip the five-second launch check. The check puts an
  icon in the menu bar and talks to whatever device is attached, so it is
  worth skipping while someone is using the machine.

What it does, in order:

1. Runs `xcodegen generate` if `project.yml` is newer than the `.xcodeproj`
   (which is git-ignored, so on a fresh clone this is what creates it).
2. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild
   -project TandemApp/Tandem.xcodeproj -scheme Tandem -configuration Release
   -derivedDataPath build/DerivedData build`, with the full log kept at
   `build/xcodebuild-release.log` and only its tail printed on failure.
   `build/` is git-ignored.
3. Verifies the product before it packages it, because a .dmg that only fails
   on someone else's Mac is the failure mode this project is most exposed to:
   - `otool -L` on the main binary **and on every dylib in
     `Contents/Frameworks`** must show no `/opt/` path — that is the invariant
     `tools/bundle-dylibs.sh` exists to establish (see "Packaging" above), and
     it is the difference between an app that runs on a Mac without Homebrew
     and one that does not;
   - `codesign --verify --deep --strict` must pass;
   - `Contents/PlugIns/TandemWidget.appex` must be present and have an
     executable — without it the widget gallery has nothing to show;
   - `Contents/Resources/Licenses` must be non-empty, since the bundled dylibs
     are LGPL/Apache and cannot ship without their texts;
   - unless `--no-launch`, the app is `open`ed in the background, must still be
     alive five seconds later, and is then quit with `osascript`.
4. Stages `Tandem.app`, an `Applications` symlink, a copy of the app's own
   `Resources/Licenses`, and a `READ ME FIRST.txt`; rolls them into a UDZO
   image with volume name `Tandem <version>`; runs `hdiutil verify`.
5. Prints the path, the size and `shasum -a 256`.

It is idempotent: the build is incremental, the staging folder is rebuilt from
scratch each time, and the .dmg is overwritten. It is not byte-reproducible,
though — the HFS+ filesystem inside the image carries timestamps, so two runs
of the same source give two different SHA-256s.

A run on this machine produced `dist/Tandem-1.0.dmg`, 5.6 MB, six bundled
dylibs and eight licence files, `codesign` reporting `Signature=adhoc` and
"satisfies its Designated Requirement".

### Gatekeeper: what the person downloading it sees

The app is signed **ad hoc** (`CODE_SIGN_IDENTITY: "-"`, see `project.yml`)
and is **not notarised**, because this project has no Apple Developer ID —
the same constraint that shapes the widget's container-path trick above.

An ad-hoc signature is internally valid (`codesign --verify` passes, the
bundle has not been tampered with) but it is anchored to nothing. Gatekeeper
does not care that the signature verifies; it cares that Apple has never seen
the binary. So a downloaded copy is quarantined and refused on first open,
usually with *"Tandem is damaged and can't be opened"* — which is misleading:
nothing is damaged, the notarisation ticket is simply absent.

`READ ME FIRST.txt` inside the image spells out the two ways round it:

```
xattr -dr com.apple.quarantine /Applications/Tandem.app
```

or right-click → Open (on recent macOS, then System Settings → Privacy &
Security → "Open Anyway"). Either is needed once, per download.

Open issues with this arrangement:

- **There is no way to fix it from inside the repo.** Notarisation needs a
  Developer ID certificate and an App Store Connect API key. With one, the
  path is: set `CODE_SIGN_IDENTITY` to the Developer ID Application identity,
  turn `ENABLE_HARDENED_RUNTIME` back on (required for notarisation, and it
  would need testing against the widget's entitlements), then
  `xcrun notarytool submit --wait` the .dmg and `xcrun stapler staple` it.
  Only the last two steps would be new to `make-dmg.sh`.
- **Hardened runtime is off.** Turning it on is a prerequisite for
  notarisation and is untested here; it interacts with the appex's sandbox
  entitlements, which the widget depends on.
- **Ad-hoc signatures are per-build.** The cdhash changes on every rebuild, so
  a user who has already granted the app something (notification permission,
  say) is not guaranteed to keep it across an upgrade.
- **`dist/` is not in `.gitignore`.** Built images should not be committed;
  either add it, or attach the .dmg to a GitHub release rather than the tree.
  tests BatteryCore and does an ad-hoc `xcodebuild` of the app on `macos-15`,
  but the image is cut by hand on a clean tree — the verification step wants
  to actually launch the app, and a CI runner has no GUI session to launch it
  into.
