import SwiftUI
import WidgetKit

struct TandemEntry: TimelineEntry {
    let date: Date
    let snapshot: TandemSnapshot?
    /// Only the large family reads `history-summary.json`, so this is `nil`
    /// for the two smaller ones rather than a file loaded and thrown away.
    var history: HistorySummary?

    var mac: DevicePresentation {
        DevicePresentation(kind: .mac, status: snapshot?.mac, now: date)
    }

    var phone: DevicePresentation {
        DevicePresentation(kind: .iphone, status: snapshot?.phone, now: date)
    }
}

/// One entry a minute for the next quarter of an hour, then a refresh — see
/// `getTimeline`. The app pushes a `reloadAllTimelines()` when a poll actually
/// changes something (throttled to once per 30 s), so the ambient policy is the
/// backstop for when the app is not running, and the per-minute entries are
/// what keep the countdown moving without polling anything at all.
struct TandemProvider: TimelineProvider {

    static let refreshInterval: TimeInterval = 15 * 60

    /// How far apart the pre-rendered entries are. One a minute is the finest
    /// granularity anything on the widget shows (`80 % · 14 min`, `4:19`).
    static let entryInterval: TimeInterval = 60

    func placeholder(in context: Context) -> TandemEntry {
        let now = Date()
        return TandemEntry(
            date: now,
            snapshot: SampleSnapshot.make(now: now),
            history: context.family == .systemLarge ? SampleHistory.make(now: now) : nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (TandemEntry) -> Void) {
        // `isPreview` is the gallery: always the 71 % / 64 % sample, never a
        // half-populated real reading.
        let now = Date()
        let snapshot = context.isPreview ? SampleSnapshot.make(now: now) : (SnapshotLoader.load() ?? SampleSnapshot.make(now: now))
        if !context.isPreview { SnapshotLoader.markVisible(family: Self.familyName(context.family), now: now) }
        let history = Self.history(family: context.family, isPreview: context.isPreview, now: now)
        completion(TandemEntry(date: now, snapshot: snapshot, history: history))
    }

    /// Two things happen here, and the second is the interesting one.
    ///
    /// 1. The breadcrumb. WidgetKit only ever asks a *placed* widget for a
    ///    timeline, so a request is the one piece of evidence available that
    ///    somebody has this widget on their desktop. The app reads the marker
    ///    on every scheduling decision and raises its phone cadence while it is
    ///    fresh (NOTES.md §14). Nothing else in the system will tell it.
    ///
    /// 2. One entry a minute rather than one entry. Every time-dependent thing
    ///    on the widget — the countdown to 80 %, the staleness dimming and the
    ///    "· 12 min" age — is computed from the entry's own date against
    ///    absolute times in the snapshot (`DeviceStatus.etaTo80At`,
    ///    `lastSeen`), so pre-rendering the next fifteen minutes makes the
    ///    widget tick without a single extra poll of the phone. The policy is
    ///    still `.after(15 min)`, which is what keeps the marker fresh.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TandemEntry>) -> Void) {
        let now = Date()
        SnapshotLoader.markVisible(family: Self.familyName(context.family), now: now)

        let snapshot = SnapshotLoader.load()
        let deadline = now.addingTimeInterval(Self.refreshInterval)

        // The large family is the exception to point 2. Its chart is a picture
        // of the last 24 h, so every pre-rendered entry would have to carry its
        // own copy of the whole series, redrawn a minute later for a plot one
        // pixel wider — fifteen archives of a 96-point chart to move a hairline.
        // One entry, refreshed on the same quarter-hour policy, is the trade.
        if context.family == .systemLarge {
            let entry = TandemEntry(date: now, snapshot: snapshot, history: HistoryLoader.load())
            completion(Timeline(entries: [entry], policy: .after(deadline)))
            return
        }

        let steps = Int(Self.refreshInterval / Self.entryInterval)
        let entries = (0..<steps).map { step in
            TandemEntry(date: now.addingTimeInterval(Double(step) * Self.entryInterval), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(deadline)))
    }

    /// The gallery gets the synthetic day; a placed large widget gets the file.
    private static func history(family: WidgetFamily, isPreview: Bool, now: Date) -> HistorySummary? {
        guard family == .systemLarge else { return nil }
        return isPreview ? SampleHistory.make(now: now) : (HistoryLoader.load() ?? SampleHistory.make(now: now))
    }

    /// `"small"` / `"medium"` / `"large"`, as written into the marker. The app
    /// only tests the marker's freshness, never its family (NOTES.md §14), so a
    /// new name here cannot break the scheduler.
    static func familyName(_ family: WidgetFamily) -> String {
        switch family {
        case .systemLarge: "large"
        case .systemMedium: "medium"
        default: "small"
        }
    }
}

struct TandemWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    /// What WidgetKit has already inset the content by. Read, not disabled:
    /// `contentMarginsDisabled()` is per-configuration and would strip the
    /// small widget's margins too, and that layout is approved as it stands.
    @Environment(\.widgetContentMargins) private var contentMargins
    let entry: TandemEntry

    var body: some View {
        Group {
            switch family {
            case .systemLarge:
                // Same reasoning as the medium tiles below: the large layout
                // measures its 14 pt inset from the widget edge, and its two
                // tiles are literally the medium ones.
                LargeWidgetView(mac: entry.mac, phone: entry.phone, history: entry.history, now: entry.date)
                    .padding(EdgeInsets(top: -contentMargins.top,
                                        leading: -contentMargins.leading,
                                        bottom: -contentMargins.bottom,
                                        trailing: -contentMargins.trailing))
            case .systemMedium:
                // The medium tiles want a 14 pt inset measured from the widget
                // edge, not from inside WidgetKit's margins, so the margins are
                // cancelled here and re-applied as `MediumWidgetView.inset`.
                MediumWidgetView(mac: entry.mac, phone: entry.phone)
                    .padding(EdgeInsets(top: -contentMargins.top,
                                        leading: -contentMargins.leading,
                                        bottom: -contentMargins.bottom,
                                        trailing: -contentMargins.trailing))
            default:
                SmallWidgetView(mac: entry.mac, phone: entry.phone)
                    // A widget cannot show a modal and has nowhere to put a
                    // detail view, so a click hands off to the app:
                    // `tandem://summary` opens the summary window over both
                    // devices. The scheme is registered in the *app's*
                    // Info.plist (TandemApp/Sources/Tandem/Info.plist);
                    // nothing in the extension has to be entitled for it.
                    //
                    // Only the small widget gets a whole-widget URL. The medium
                    // one is two devices side by side and gives each tile its
                    // own `Link` (`MediumWidgetView.link`), so a click says
                    // which device it meant.
                    .widgetURL(URL(string: "tandem://summary"))
            }
        }
        // Measured, not guessed — and the measuring is the point, because a
        // macOS desktop widget has *two* looks and only one of them shows this
        // modifier at all.
        //
        // While an app window is in front, the host desaturates every desktop
        // widget and substitutes its own translucent material; whatever is put
        // here is irrelevant, and every candidate below measured the same. But
        // the moment the desktop is revealed — which is exactly when anyone
        // looks at their widgets, and what the user's screenshots showed — the
        // host hands the widget its own colours *and its own background*, and
        // the difference is stark. Sampled from one ScreenCaptureKit frame
        // containing only the wallpaper and the desktop widget windows:
        //
        //   this widget, `.fill.tertiary` (Xcode's template)  #0D0D0D, flat
        //   this widget, `Color.clear`                        #222221, flat
        //   Batteries, same frame   #4F4F54 → #2B2D33 across the widget
        //   Calendar,  same frame   #515151 → #3C3D3C across the widget
        //
        // The system widgets' backgrounds *vary* across their own width: they
        // are translucent over the wallpaper. Ours did not vary: it was an
        // opaque near-black plate. Neither a transparent background nor a
        // hierarchical fill has anything to be translucent against, so both
        // land on the black the host leaves behind. A `Material` is the one
        // SwiftUI background that samples what is behind it, which is what the
        // system's own widgets evidently do.
        //
        // One more trap when checking any of this: a placed widget keeps
        // rendering the archive its *running* appex process produced.
        // Rebuilding and relaunching the app is not enough — the earlier fix
        // here looked like it had done nothing for exactly that reason.
        // `pkill -f TandemWidget.appex` is what lets new code reach the
        // desktop; chronod relaunches it on the next reload.
        .containerBackground(.regularMaterial, for: .widget)
    }
}

struct TandemWidget: Widget {
    let kind = "dev.tandem.widget.battery"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TandemProvider()) { entry in
            TandemWidgetEntryView(entry: entry)
        }
        .configurationDisplayName(Text("Tandem Battery", comment: "Widget name in the gallery."))
        .description(Text("MacBook and iPhone charge side by side.", comment: "Widget description in the gallery."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct TandemWidgetBundle: WidgetBundle {
    var body: some Widget {
        TandemWidget()
    }
}
