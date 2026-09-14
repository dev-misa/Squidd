import SwiftUI
import AppKit
import ImageIO

enum WidgetMetrics {
    static let card = CGSize(width: 316, height: 192)
    static let launcher = CGSize(width: 169, height: 80)

    // Launcher pill. The logo always shows; album art and the mascot join it only when there's something to draw,
    // so with neither the pill is as wide as it is tall and reads as a circle around the logo.
    static let pillHeight: CGFloat = 52
    static let pillSpacing: CGFloat = 7
    static let pillLeading: CGFloat = 6
    static let logoSize: CGFloat = 40
    static let artSize: CGFloat = 40
    static let mascotSize: CGFloat = 35

    /// Without a mascot, extra trailing room keeps the art's corners as far from the pill's curve as the logo is.
    static func pillTrailing(artwork: Bool, mascot: Bool) -> CGFloat { artwork && !mascot ? 16 : pillLeading }

    /// The pill within a launcher panel of `size`. Centered both ways, so it sits over the middle of the card however
    /// many items it holds, and is the same in flipped and unflipped views.
    static func pillRect(inLauncher size: CGSize, artwork: Bool, mascot: Bool) -> CGRect {
        let width = pillWidth(artwork: artwork, mascot: mascot)
        return CGRect(x: (size.width - width) / 2, y: (size.height - pillHeight) / 2, width: width, height: pillHeight)
    }

    /// The logo's circle within a launcher panel of `size`, the same in flipped and unflipped views.
    static func logoRect(inLauncher size: CGSize, artwork: Bool, mascot: Bool) -> CGRect {
        let pill = pillRect(inLauncher: size, artwork: artwork, mascot: mascot)
        return CGRect(x: pill.minX + pillLeading, y: (size.height - logoSize) / 2, width: logoSize, height: logoSize)
    }

    static func pillWidth(artwork: Bool, mascot: Bool) -> CGFloat {
        var width = pillLeading + logoSize
        if artwork { width += pillSpacing + artSize }
        if mascot { width += pillSpacing + mascotSize }
        return width + pillTrailing(artwork: artwork, mascot: mascot)
    }
}

struct NativeGlass: ViewModifier {
    var radius: CGFloat
    var appearance: WidgetAppearance = .light
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// The panels don't override their appearance, so this follows System Settings › Appearance live.
    @Environment(\.colorScheme) private var colorScheme

    private var dark: Bool { appearance.isDark(in: colorScheme) }

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background {
                // Dark: the same clear glass under a deep tint, so white text stays readable over bright windows.
                RoundedRectangle(cornerRadius: radius)
                    .fill(.black.opacity(dark ? 0.5 : 0))
                    .allowsHitTesting(false)
            }
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(.ultraThinMaterial)
                    .opacity(0.2)
                    .allowsHitTesting(false)
            }
            .background {
                Color.clear
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: radius))
                    .opacity(0.88)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The dashed ring around the card: white in Light, near-black in Dark to match the tinted card.
struct CardOutline: View {
    var appearance: WidgetAppearance
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 29).inset(by: 1)
            .stroke(appearance.isDark(in: colorScheme) ? Color(white: 0.08).opacity(0.85) : Color.white.opacity(0.85),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 7]))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ContentView: View {
    var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                PreviewArtwork(store: store, radius: 15).frame(width: 80, height: 80)
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.title).font(.system(size: 12, weight: .bold))
                        Text(store.artist).font(.system(size: 9, weight: .bold))
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7).padding(.horizontal, 11)
                    .background(store.ink == .scrim ? .black.opacity(0.35) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    HStack {
                        transport(.previous, label: "Previous track")
                        Spacer(minLength: 0)
                        transport(store.isPlaying ? .pause : .play, label: store.isPlaying ? "Pause" : "Play")
                        Spacer(minLength: 0)
                        transport(.next, label: "Next track")
                    }.padding(.horizontal, 6)
                }
            }.frame(maxHeight: .infinity)
            HStack(spacing: 9) {
                if store.showsTimeline {
                    Text(time(store.elapsed))
                    SeekBarView(elapsed: store.elapsed, duration: store.shownDuration, enabled: store.canSeek) { store.seek(to: $0) }
                        .id(store.trackIdentity)
                    Text(time(store.shownDuration))
                }
            }
            .frame(height: 9)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .padding(.bottom, 28)
        }
        .padding(.leading, 17).padding(.trailing, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(2)
        .modifier(NativeGlass(radius: 24, appearance: store.widgetAppearance))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.5), lineWidth: 0.5).allowsHitTesting(false) }
        .foregroundStyle(reduceTransparency || contrast == .increased ? Color.primary : (store.ink == .dark ? Color(white: 0.07) : .white))
        .overlay {
            PlaybackParticles(active: store.isPlaying && store.cardVisible && !store.sleeping,
                              store: store)
        }
        .padding(6)
        .overlay {
            if store.showCardOutline { CardOutline(appearance: store.widgetAppearance) }
        }
    }

    private func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }

    private func transport(_ kind: TransportGlyph.Kind, label: String) -> some View {
        let command: PlaybackCommand = switch kind {
        case .previous: .previous
        case .next: .next
        case .pause: .pause
        case .play: .play
        }
        return TransportButton(kind: kind, label: label, enabled: store.offers(command)) {
            if kind == .previous || kind == .next { store.skip(previous: kind == .previous) } else { store.togglePlayback() }
        }
    }

}

struct ArtworkPlaceholder: View {
    var radius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: radius).fill(.white.opacity(0.03))
            .accessibilityLabel("No album artwork")
    }
}

struct LauncherView: View {
    var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A critically damped spring: quick off the mark, a long soft settle, no overshoot.
    private static let resize = Animation.smooth(duration: 0.45)
    /// Album art and the mascot slide out from behind whatever sits to their left, and back behind it when hidden.
    private static let slotTransition = AnyTransition.modifier(active: TuckedBehindNeighbor(progress: 0),
                                                               identity: TuckedBehindNeighbor(progress: 1))
    var body: some View {
        let artwork = store.pillShowsArtwork
        let mascot = store.pillMascotURL
        return HStack(spacing: WidgetMetrics.pillSpacing) {
            ZStack {
                if store.showLogoCircle { Circle().fill(store.logoCircleColor) }
                // Same share of the circle the logo took in the original app-icon artwork (700 of 1024 px).
                SquiddLogo(primary: store.logoPrimaryColor, highlight: store.logoHighlightColor)
                    .frame(width: WidgetMetrics.logoSize * 700 / 1024)
            }
            .frame(width: WidgetMetrics.logoSize, height: WidgetMetrics.logoSize)
            // Pressed feedback: a slight shrink and fade, springing back on release. Reduce Motion keeps just the fade.
            .scaleEffect(store.logoPressed && !reduceMotion ? 0.9 : 1)
            .opacity(store.logoPressed ? 0.7 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.3), value: store.logoPressed)
            // Each item stacks above the one to its right, so a sliding item passes behind its neighbor.
            .zIndex(2)
            if artwork {
                PreviewArtwork(store: store, radius: 10)
                    .frame(width: WidgetMetrics.artSize, height: WidgetMetrics.artSize)
                    .transition(Self.slotTransition)
                    .zIndex(1)
            }
            if let mascot {
                AnimatedMascotView(playing: store.isPlaying && !store.sleeping, customURL: mascot)
                    .frame(width: WidgetMetrics.mascotSize, height: WidgetMetrics.mascotSize)
                    .transition(Self.slotTransition)
                    .zIndex(0)
            }
        }
        .padding(.leading, WidgetMetrics.pillLeading)
        .padding(.trailing, WidgetMetrics.pillTrailing(artwork: artwork, mascot: mascot != nil))
        .frame(height: WidgetMetrics.pillHeight)
        .modifier(NativeGlass(radius: WidgetMetrics.pillHeight / 2, appearance: store.widgetAppearance))
        .overlay { PlaybackRim(playing: store.isPlaying && !store.sleeping, primaryColor: store.rimPrimaryColor, accentColor: store.rimAccentColor) }
        // Centered in the panel, so a pill with only one or two items still sits over the middle of the card.
        .frame(width: WidgetMetrics.launcher.width, height: WidgetMetrics.launcher.height)
        // One transaction for the glass, the rim and the contents, so they all move together.
        .animation(reduceMotion ? nil : Self.resize, value: artwork)
        .animation(reduceMotion ? nil : Self.resize, value: mascot)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Squidd launcher")
    }
}

/// A pill item's slide in and out. At 0 it sits small, exactly behind its left neighbor (the logo or the album art —
/// both 40 pt wide, so the distance is the same either way); at 1 it's full size in its own slot, so it grows as it
/// emerges and shrinks as it tucks away. Opacity rises only over the first quarter, so a leaving item stays solid
/// until it's nearly hidden instead of fading out ahead of the pill.
struct TuckedBehindNeighbor: ViewModifier, Animatable {
    static let hiddenScale = 0.4
    var progress: Double
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(Self.hiddenScale + (1 - Self.hiddenScale) * progress)
            .offset(x: -(WidgetMetrics.logoSize + WidgetMetrics.pillSpacing) * (1 - progress))
            .opacity(min(1, max(0, progress / 0.25)))
    }
}

/// The Squidd logo as two tintable vector layers, shared by the launcher pill and the Settings header.
struct SquiddLogo: View {
    var primary: Color
    var highlight: Color

    var body: some View {
        ZStack {
            Image("Squidd-Logo-Primary").renderingMode(.template).resizable().foregroundStyle(primary)
            Image("Squidd-Logo-Highlight").renderingMode(.template).resizable().foregroundStyle(highlight)
        }
        .aspectRatio(52.0 / 53.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// Original Electron SVG coordinates; previous is the mirrored next glyph.
struct TransportGlyph: Shape {
    enum Kind { case previous, play, pause, next }
    var kind: Kind

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if kind == .pause {
            p.move(to: CGPoint(x: 9, y: 5.75058)); p.addLine(to: CGPoint(x: 9, y: 18.2506))
            p.move(to: CGPoint(x: 13, y: 5.75058)); p.addLine(to: CGPoint(x: 13, y: 18.2506))
            return p.applying(CGAffineTransform(scaleX: rect.width / 22, y: rect.height / 24))
        }
        if kind == .play {
            p.move(to: CGPoint(x: 4.77546, y: 2.85028))
            p.addLine(to: CGPoint(x: 9.24431, y: 5.82951))
            p.addCurve(to: CGPoint(x: 9.24431, y: 10.4058), control1: CGPoint(x: 10.8771, y: 6.91802), control2: CGPoint(x: 10.8771, y: 9.31727))
            p.addLine(to: CGPoint(x: 4.77547, y: 13.385))
            p.addCurve(to: CGPoint(x: 0.500042, y: 11.0969), control1: CGPoint(x: 2.94794, y: 14.6034), control2: CGPoint(x: 0.500042, y: 13.2933))
            p.addLine(to: CGPoint(x: 0.500042, y: 5.13842))
            p.addCurve(to: CGPoint(x: 4.77546, y: 2.85028), control1: CGPoint(x: 0.500042, y: 2.94201), control2: CGPoint(x: 2.94794, y: 1.63193))
            p.closeSubpath()
            return p.applying(CGAffineTransform(translationX: 5.5, y: 4.03))
                .applying(CGAffineTransform(scaleX: rect.width / 22, y: rect.height / 24))
        }
        p.move(to: CGPoint(x: 4.77542, y: 2.85028))
        p.addLine(to: CGPoint(x: 14.3178, y: 9.21186))
        p.addCurve(to: CGPoint(x: 14.3178, y: 13.7881), control1: CGPoint(x: 15.9506, y: 10.3004), control2: CGPoint(x: 15.9506, y: 12.6996))
        p.addLine(to: CGPoint(x: 4.77542, y: 20.1497))
        p.addCurve(to: CGPoint(x: 0.499998, y: 17.8616), control1: CGPoint(x: 2.9479, y: 21.3681), control2: CGPoint(x: 0.499998, y: 20.058))
        p.addLine(to: CGPoint(x: 0.499998, y: 5.13842))
        p.addCurve(to: CGPoint(x: 4.77542, y: 2.85028), control1: CGPoint(x: 0.499998, y: 2.94201), control2: CGPoint(x: 2.9479, y: 1.63193))
        p.closeSubpath()
        p.move(to: CGPoint(x: 25.0695, y: 5.89441))
        p.addLine(to: CGPoint(x: 29.5384, y: 8.87364))
        p.addCurve(to: CGPoint(x: 29.5384, y: 13.4499), control1: CGPoint(x: 31.1711, y: 9.96215), control2: CGPoint(x: 31.1711, y: 12.3614))
        p.addLine(to: CGPoint(x: 25.0695, y: 16.4291))
        p.addCurve(to: CGPoint(x: 20.7941, y: 14.141), control1: CGPoint(x: 23.242, y: 17.6475), control2: CGPoint(x: 20.7941, y: 16.3374))
        p.addLine(to: CGPoint(x: 20.7941, y: 8.18255))
        p.addCurve(to: CGPoint(x: 25.0695, y: 5.89441), control1: CGPoint(x: 20.7941, y: 5.98614), control2: CGPoint(x: 23.242, y: 4.67606))
        p.closeSubpath()
        if kind == .previous { p = p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 32.9706, ty: 0)) }
        return p.applying(CGAffineTransform(scaleX: rect.width / 33, y: rect.height / 23))
    }
}

struct PreviewArtwork: View {
    var store: AppStore
    var radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            ArtworkPlaceholder(radius: radius)
            if let artwork = store.artwork {
                GeometryReader { geometry in
                    Image(nsImage: artwork).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: radius))
                }
                .id(ObjectIdentifier(artwork))
                .transition(.opacity)
            } else if store.preview != .off && store.canControl {
                RoundedRectangle(cornerRadius: radius)
                    .fill(LinearGradient(colors: store.sampleIndex == 0 ? [.purple, .indigo] : [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay { Image(systemName: "music.note").foregroundStyle(.white.opacity(0.8)) }
                    .id(store.sampleIndex)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: store.artwork.map { ObjectIdentifier($0) })
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: store.sampleIndex)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: store.artwork != nil)
        .accessibilityLabel(store.artwork != nil ? "Album artwork" : (store.preview != .off && store.canControl ? "Preview artwork" : "No album artwork"))
    }
}
