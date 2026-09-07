import SwiftUI
import AppKit
import BatteryCore

/// The compact status-item label: two glyph+percent pairs, monochrome only.
///
/// This is rendered to a bitmap (`ImageRenderer` -> `NSImage`, marked
/// `.isTemplate`) rather than shown as a live SwiftUI `HStack`/`Text`.
/// Two live approaches were tried first and both failed silently in
/// practice: an `HStack` mixing several `Image`/`Text` views dropped
/// everything after the first icon+percent pair, and a single concatenated
/// `Text` with `Image(systemName:)` runs reserved the right width and even
/// showed up in the accessibility title (as "\u{FFFC}" placeholders) but
/// never painted any pixels for the glyphs. Both point at `MenuBarExtra`
/// flattening the label into an `NSStatusBarButton` title/image that
/// doesn't reliably support multiple inline image attachments. Rasterizing
/// ourselves sidesteps that entirely.
struct MenuBarLabelView: View {
    @Environment(TandemModel.self) private var model

    var body: some View {
        Group {
            if let image = renderedImage {
                Image(nsImage: image)
            } else {
                Text(verbatim: "…")
            }
        }
    }

    /// The rasterisation is the expensive part of a poll's UI cost, and most
    /// polls change nothing the label shows, so it is keyed on
    /// `MenuBarLabelState` (two percents and two charging flags) and reused
    /// until one of those four numbers actually moves.
    private var renderedImage: NSImage? {
        model.menuBarCache.image(for: model.menuBarLabelState)
    }
}

/// Keeps the last rasterised label, so an unchanged label is never re-rendered.
///
/// A class rather than a `@State` value because `MenuBarExtra`'s label view is
/// re-evaluated on every observable change, and the cache has to outlive those
/// evaluations.
///
/// **Why the label used to come out pixelated.** The raster was made at
/// `NSScreen.main?.backingScaleFactor`, and `NSScreen.main` is *not* the screen
/// the menu bar is on: it is the screen holding the window with keyboard focus.
/// On this machine (a 2x built-in display plus a 1x external one) that is the
/// 1x display whenever the frontmost app's window is over there, so the label
/// was rasterised at 1x — 117 x 19 real pixels, confirmed from the flattened
/// TIFF — and then drawn into a 2x menu bar, where AppKit doubled it with
/// interpolation. It stayed that way until one of the four numbers in
/// `MenuBarLabelState` moved, which is why it was blurry only *sometimes*.
/// The fix is to rasterise for the sharpest screen attached, whichever one has
/// focus, and to re-render when the screens change.
@MainActor
@Observable
final class MenuBarLabelCache {

    /// Bumped on `NSApplication.didChangeScreenParametersNotification`. Read
    /// inside `image(for:)`, so a display being plugged in, unplugged or
    /// rescaled invalidates the label the same way a changed percent does.
    private(set) var screenGeneration = 0

    @ObservationIgnored private var state: MenuBarLabelState?
    @ObservationIgnored private var renderedScale: CGFloat = 0
    @ObservationIgnored private var image: NSImage?
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenGeneration += 1 }
        }
    }

    /// The cached raster, keyed by the label's state *and* the scale it was
    /// drawn for.
    func image(for state: MenuBarLabelState) -> NSImage? {
        _ = screenGeneration
        let scale = Self.renderScale
        if let image, self.state == state, renderedScale == scale { return image }
        guard let rendered = Self.render(state, scale: scale) else { return image }
        self.state = state
        self.renderedScale = scale
        self.image = rendered
        return rendered
    }

    /// The sharpest backing scale attached, because the menu bar can be on any
    /// of them (and is on all of them when displays have separate spaces).
    /// Over-rendering costs a few kilobytes and downsamples cleanly;
    /// under-rendering is the bug above.
    private static var renderScale: CGFloat {
        max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2, 1)
    }

    /// Rasterise the label at `scale`, on whole points.
    ///
    /// The size is measured first and handed back as `proposedSize` rounded up
    /// to whole points, and the `NSImage` is built from the `CGImage` with its
    /// point size pinned to `pixels / scale` — so the bitmap is an exact whole
    /// multiple of the size the status item lays out, and nothing is resampled.
    private static func render(_ state: MenuBarLabelState, scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: MenuBarArtwork(mac: state.mac, phone: state.phone))
        renderer.scale = scale

        var ideal = CGSize.zero
        renderer.render { size, _ in ideal = size }
        if ideal.width > 0, ideal.height > 0 {
            renderer.proposedSize = ProposedViewSize(
                width: ideal.width.rounded(.up),
                height: ideal.height.rounded(.up)
            )
        }

        guard let cgImage = renderer.cgImage else { return nil }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        let points = CGSize(
            width: (CGFloat(cgImage.width) / scale).rounded(),
            height: (CGFloat(cgImage.height) / scale).rounded()
        )
        representation.size = points
        let image = NSImage(size: points)
        image.addRepresentation(representation)
        image.isTemplate = true
        return image
    }
}
