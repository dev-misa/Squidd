import SwiftUI
import AppKit
import ImageIO

struct SeekBarView: View {
    var elapsed: Double
    var duration: Double
    var enabled: Bool
    var seek: (Double) -> Void
    @State private var preview: Double?
    @State private var hovered = false

    var body: some View {
        GeometryReader { geometry in
            let fraction = preview ?? (duration > 0 ? elapsed / duration : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.32)).frame(height: 4)
                Capsule().frame(width: max(0, geometry.size.width * fraction), height: 4)
                Circle().frame(width: 8, height: 8)
                    .scaleEffect(hovered || preview != nil ? 1.4 : 1)
                    .offset(x: geometry.size.width * fraction - 4)
            }
            .frame(height: 22).contentShape(Rectangle())
            .onHover { hovered = $0 }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard enabled && duration > 0 else { return }
                preview = max(0, min(1, value.location.x / max(1, geometry.size.width)))
            }.onEnded { _ in
                if let preview, enabled { seek(preview * duration) }
                preview = nil
            })
            .offset(y: -6.5)
        }
        .frame(height: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(enabled ? "\(Int((preview ?? (duration > 0 ? elapsed / duration : 0)) * 100)) percent" : "Unavailable")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: seek(min(duration, elapsed + 5))
            case .decrement: seek(max(0, elapsed - 5))
            @unknown default: break
            }
        }
        .focusable(enabled)
        .onKeyPress(.leftArrow) { guard enabled else { return .ignored }; seek(max(0, elapsed - 5)); return .handled }
        .onKeyPress(.rightArrow) { guard enabled else { return .ignored }; seek(min(duration, elapsed + 5)); return .handled }
    }
}

@MainActor @Observable
final class MascotFrames {
    struct Frame {
        let image: NSImage
        let delay: Double
    }
    private(set) var frames: [Frame] = []
    /// Average visual center of the frames, as a fraction of their height from the top.
    private(set) var visualCenterY = 0.5
    var index = 0
    var remaining: Double = 0

    func load(customURL: URL?) {
        guard let customURL, let source = CGImageSourceCreateWithURL(customURL as CFURL, nil) else {
            frames = []; visualCenterY = 0.5; index = 0; remaining = 0; return
        }
        let decoded: [(image: CGImage, delay: Double)] = (0..<CGImageSourceGetCount(source)).compactMap { index in
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            return (image, max(0.02, delay))
        }
        // One crop shared by every frame, so the visible content is centered without jittering between frames.
        let layout = Self.visibleLayout(of: decoded.map(\.image))
        frames = decoded.map { frame in
            let image = layout.box.flatMap { frame.image.cropping(to: $0) } ?? frame.image
            return Frame(image: NSImage(cgImage: image, size: .zero), delay: frame.delay)
        }
        visualCenterY = layout.centerY
        index = 0
        remaining = frames.first?.delay ?? 0.1
    }

    /// Moves the frames so their average visual center, not their box center, sits mid-slot.
    /// Capped at a fifth of the slot so tall poses stay inside the launcher.
    func verticalOffset(in slot: CGSize) -> CGFloat {
        guard let size = frames.first?.image.size, size.width > 0, size.height > 0 else { return 0 }
        let rendered = min(slot.height, slot.width * size.height / size.width)
        let offset = (0.5 - visualCenterY) * rendered
        return min(slot.height / 5, max(-slot.height / 5, offset))
    }

    /// Box around the non-transparent pixels of all frames (top-left pixel coordinates; nil when there is
    /// no transparent margin to trim), and the frames' average alpha-weighted center as a fraction of its height.
    static func visibleLayout(of images: [CGImage]) -> (box: CGRect?, centerY: Double) {
        guard let first = images.first,
              images.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { return (nil, 0.5) }
        // Measure on a small copy; single-pixel precision doesn't matter in a 35-point slot.
        let scale = min(1, 128 / Double(max(first.width, first.height)))
        let width = max(1, Int(Double(first.width) * scale)), height = max(1, Int(Double(first.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return (nil, 0.5) }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        var centerSum = 0.0, measured = 0
        for image in images {
            context.clear(rect)
            context.draw(image, in: rect)
            var weightedY = 0.0, weight = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let alpha = pixels[(y * width + x) * 4 + 3]
                    guard alpha > 8 else { continue }
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    weightedY += (Double(y) + 0.5) * Double(alpha); weight += Double(alpha)
                }
            }
            if weight > 0 { centerSum += weightedY / weight; measured += 1 }
        }
        guard maxX >= 0, measured > 0 else { return (nil, 0.5) }
        let sx = Double(first.width) / Double(width), sy = Double(first.height) / Double(height)
        let full = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        let trims = minX > 0 || minY > 0 || maxX < width - 1 || maxY < height - 1
        let box = trims ? CGRect(x: Double(minX - 1) * sx, y: Double(minY - 1) * sy,
                                 width: Double(maxX - minX + 3) * sx, height: Double(maxY - minY + 3) * sy).integral.intersection(full) : nil
        let shown = box ?? full
        let centerY = (centerSum / Double(measured) * sy - shown.minY) / shown.height
        return (box, min(1, max(0, centerY)))
    }

    func run() async {
        guard !frames.isEmpty else { return }
        while !Task.isCancelled {
            let started = ProcessInfo.processInfo.systemUptime
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch {
                remaining = max(0.001, remaining - (ProcessInfo.processInfo.systemUptime - started))
                return
            }
            index = (index + 1) % frames.count
            remaining = frames[index].delay
        }
    }
}

struct AnimatedMascotView: View {
    var playing: Bool
    var customURL: URL?
    @State private var frames = MascotFrames()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { slot in
            Group {
                if !frames.frames.isEmpty { Image(nsImage: frames.frames[frames.index].image).resizable().scaledToFit() }
                else { Image(systemName: "music.note") }
            }
            .frame(width: slot.size.width, height: slot.size.height)
            .offset(y: frames.verticalOffset(in: slot.size))
        }
        .task(id: customURL) { frames.load(customURL: customURL) }
        .task(id: playing && !reduceMotion) {
            if playing && !reduceMotion { await frames.run() }
        }
        .accessibilityHidden(true)
    }
}

struct PlaybackRim: View {
    var playing: Bool
    var primaryColor: Color = AppStore.defaultRimPrimary
    var accentColor: Color = AppStore.defaultRimAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var elapsed: TimeInterval = 0
    @State private var started: Date?

    private var moving: Bool { playing && !reduceMotion }

    var body: some View {
        TimelineView(.animation(paused: !moving)) { context in
            let time = elapsed + (started.map { max(0, context.date.timeIntervalSince($0)) } ?? 0)
            let highlights = Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)
                let outline = Capsule().path(in: rect)
                let phase = (time / 8).truncatingRemainder(dividingBy: 1)
                // Continuous shading avoids overlapping short strokes and visible stepping.
                for index in 0..<2 {
                    let position = (phase + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                    let center = perimeterPoint(position, in: rect)
                    let strength = index == 0 ? 1.0 : 0.45
                    context.stroke(outline, with: .radialGradient(
                        Gradient(stops: [
                            .init(color: accentColor.opacity(strength), location: 0),
                            .init(color: accentColor.opacity(strength * 0.55), location: 0.4),
                            .init(color: accentColor.opacity(0), location: 1)
                        ]), center: center, startRadius: 0, endRadius: rect.height * 0.85),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }

            ZStack {
                // A quiet glass edge stays visible while playback is paused.
                Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.12), .white.opacity(0.3)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6)
                Capsule().inset(by: 1.5).strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.15), .clear, .black.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                ZStack {
                    Capsule().strokeBorder(primaryColor.opacity(0.75), lineWidth: 0.8)
                    Capsule().strokeBorder(primaryColor, lineWidth: 2)
                        .blur(radius: 4).opacity(0.3)
                    highlights.blur(radius: 3).opacity(0.65)
                    highlights
                }
                .opacity(playing ? 1 : 0)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: playing)
        }
        // Preserve the light's position across pause/resume, without a polling task.
        .onChange(of: moving, initial: true) { _, moving in
            if moving {
                started = Date()
            } else if let started {
                elapsed += max(0, Date().timeIntervalSince(started))
                self.started = nil
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Arc-length positioning keeps the highlights moving evenly across straights and curves.
    private func perimeterPoint(_ fraction: Double, in rect: CGRect) -> CGPoint {
        let radius = rect.height / 2
        let straight = max(0, rect.width - rect.height)
        let arc = CGFloat.pi * radius
        var distance = CGFloat(fraction) * (2 * straight + 2 * arc)
        if distance < straight {
            return CGPoint(x: rect.minX + radius + distance, y: rect.minY)
        }
        distance -= straight
        if distance < arc {
            let angle = distance / radius - .pi / 2
            return CGPoint(x: rect.maxX - radius + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
        }
        distance -= arc
        if distance < straight {
            return CGPoint(x: rect.maxX - radius - distance, y: rect.maxY)
        }
        distance -= straight
        let angle = distance / radius + .pi / 2
        return CGPoint(x: rect.minX + radius + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
    }

}

struct PlaybackParticles: View {
    var active: Bool
    var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var particles: [Particle] = []
    @State private var previousGlyph = ""
    struct Particle: Identifiable {
        let id = UUID()
        let born = Date()
        let glyph: String
        let fraction: Double
        let size = Double.random(in: 19...24)
        let duration = Double.random(in: 2.4...3.6)
        let rise = Double.random(in: 58...88)
        let drift = Double.random(in: 9...26) * (Bool.random() ? 1 : -1)
        let peak = Double.random(in: 0.75...1)
    }
    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: particles.isEmpty || reduceMotion)) { context in
                ZStack {
                    ForEach(particles) { particle in
                        let progress = min(1, max(0, context.date.timeIntervalSince(particle.born) / particle.duration))
                        let alpha = progress < 0.18 ? progress / 0.18 : (progress > 0.72 ? (1 - progress) / 0.28 : 1)
                        Text(particle.glyph).font(.system(size: particle.size))
                            .foregroundStyle(.white)
                            .scaleEffect(progress < 0.55 ? 0.6 + progress / 0.55 * 0.4 : 1 - (progress - 0.55) / 0.45 * 0.08)
                            .rotationEffect(.degrees(particle.drift * 0.9 * progress))
                            .opacity(alpha * particle.peak)
                            .position(x: 48 + max(0, geometry.size.width - 99) * particle.fraction + particle.drift * progress,
                                      y: geometry.size.height - 40 - particle.rise * progress)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .allowsHitTesting(false).accessibilityHidden(true)
        .task(id: active && !reduceMotion) {
            guard active && !reduceMotion else { particles = []; return }
            while !Task.isCancelled {
                particles.removeAll { Date().timeIntervalSince($0.born) >= $0.duration }
                let glyph = store.artist.localizedCaseInsensitiveContains("sabrina carpenter") ? "💋" : ["♪", "♫", "♩", "♬"].filter { $0 != previousGlyph }.randomElement()!
                if particles.count < 8 { particles.append(Particle(glyph: glyph, fraction: store.duration > 0 ? store.elapsed / store.duration : 0)); previousGlyph = glyph }
                do { try await Task.sleep(for: .milliseconds(780)) } catch { return }
            }
        }
    }
}

struct TransportButton: View {
    var kind: TransportGlyph.Kind
    var label: String
    var enabled: Bool
    var action: () -> Void
    @State private var pressed = false

    var body: some View {
        Button {
            pressed = true
            action()
        } label: {
            // The press fills with the outline's own color — white, or dark grey under dark ink — not the gray primary.
            TransportGlyph(kind: kind)
                .fill(.foreground)
                .opacity(pressed ? 1 : 0)
                .overlay { TransportGlyph(kind: kind).stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)) }
                .frame(width: kind == .play || kind == .pause ? 22 : 33, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label)
        .task(id: pressed) {
            if pressed { try? await Task.sleep(for: .milliseconds(180)); pressed = false }
        }
    }
}
