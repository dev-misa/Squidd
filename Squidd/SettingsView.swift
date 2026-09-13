import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Edge- and corner-drag callbacks into the settings window.
struct SettingsResize {
    var update: (SettingsWindow.Handle) -> Void = { _ in }
    var end: () -> Void = {}
}

// Borderless so Settings can draw its own rounded glass panel; still becomes key so the Client ID field accepts typing.
@MainActor
final class SettingsWindow: NSWindow {
    enum Handle {
        case top, bottom, leading, trailing, topLeading, topTrailing, bottomLeading, bottomTrailing

        var changesWidth: Bool { self != .top && self != .bottom }
        var changesHeight: Bool { self != .leading && self != .trailing }
        /// Dragging from the panel's right side or its bottom, so the opposite side is the one that stays put.
        var fromTrailing: Bool { self == .trailing || self == .topTrailing || self == .bottomTrailing }
        var fromBottom: Bool { self == .bottom || self == .bottomLeading || self == .bottomTrailing }
    }

    private var resizeStart: (frame: NSRect, mouse: NSPoint)?

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // macOS builds the shadow from the square window surface, which leaves marks outside the rounded corners.
        hasShadow = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // The opposite edge or corner stays put. Screen coordinates are used so the moving window doesn't feed back
    // into the drag. An edge handle changes only its own dimension.
    func resize(from handle: Handle) {
        let mouse = NSEvent.mouseLocation
        if resizeStart == nil { resizeStart = (frame, mouse) }
        guard let start = resizeStart else { return }
        let limit = (screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 10_000, height: 10_000)
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        // Screen y grows upward, so dragging the bottom downwards makes the panel taller.
        let width = handle.changesWidth
            ? min(max(start.frame.width + (handle.fromTrailing ? dx : -dx), SettingsView.minimumSize.width), limit.width)
            : start.frame.width
        let height = handle.changesHeight
            ? min(max(start.frame.height + (handle.fromBottom ? -dy : dy), SettingsView.minimumSize.height), limit.height)
            : start.frame.height
        let origin = NSPoint(x: handle.changesWidth && !handle.fromTrailing ? start.frame.maxX - width : start.frame.minX,
                             y: handle.changesHeight && handle.fromBottom ? start.frame.maxY - height : start.frame.minY)
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        invalidateShadow()
    }

    func endResize() {
        resizeStart = nil
        invalidateShadow()
    }
}

// The content column stays centered in the panel; its headings and controls share a left edge.
// Resizing preserves that column while distributing vertical space between sections.
struct SettingsView: View {
    static let defaultSize = CGSize(width: 440, height: 690)
    // Keeps the widest controls comfortably inside the rounded panel.
    static let minimumSize = CGSize(width: 440, height: 690)
    fileprivate static let columnWidth: CGFloat = 440
    private static let contentWidth: CGFloat = 349

    @Bindable var store: AppStore
    var close: () -> Void
    var resize = SettingsResize()
    @State private var clientID = ""
    @State private var copiedRedirect = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let panelShape = RoundedRectangle(cornerRadius: SettingsStyle.cornerRadius)

    var body: some View {
        column
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(panelShape)
            .background { background }
            // Press and drag anywhere to move the panel; a plain click still reaches buttons and the text field.
            .simultaneousGesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
            .overlay { resizeHandles }
            // Above the resize grips, so the close button always gets its own clicks.
            .overlay(alignment: .topLeading) { closeButton.padding(.leading, 22).padding(.top, 19) }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .onAppear { clientID = store.spotify.clientID }
    }

    // MARK: Layout

    private var column: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 31)
            header
            gap
            spotifyID
            gap
            spotifyConnect
            gap
            appearance
            gap
            pillArtwork
            gap
            mascot
            gap
            accent
            gap
            outline
            // Keeps the commands near the checkbox; leftover height collects at the bottom instead.
            Spacer(minLength: 16).frame(maxHeight: 40)
            shortcuts
            Spacer(minLength: 32)
        }
    }

    private var gap: some View { Spacer(minLength: 16) }

    /// Left-align every section inside the same centered content column.
    private func centeredColumn<Content: View>(spacing: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) { content() }
            .fixedSize()
            .frame(width: Self.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    /// Fixed horizontal space inside a row, taken from the design.
    private func space(_ width: CGFloat) -> some View { Color.clear.frame(width: width, height: 1) }

    // MARK: Chrome

    private var background: some View {
        ZStack {
            if reduceTransparency {
                panelShape.fill(SettingsStyle.panel)
                panelShape.strokeBorder(.white.opacity(0.16), lineWidth: 1)
            } else {
                Color.clear.glassEffect(.regular, in: panelShape)
            }
            // Near-clear layer so empty panel areas still receive the drag.
            panelShape.fill(.white.opacity(0.001))
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(SettingsStyle.font(13, .semibold))
                .frame(width: 25, height: 25)
                .background(Circle().fill(.white.opacity(0.14)))
                .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close Settings")
    }

    private var resizeHandles: some View {
        ZStack {
            // Edges first; the corner handles sit on top of their ends. The top-left corner has none: the close
            // button lives there, and a grip around it turned near-misses into resizes.
            edgeHandle(.top, .top, .top)
            edgeHandle(.bottom, .bottom, .bottom)
            edgeHandle(.leading, .leading, .leading)
            edgeHandle(.trailing, .trailing, .trailing)
            cornerHandle(.topTrailing, .topTrailing, .topTrailing)
            cornerHandle(.bottomLeading, .bottomLeading, .bottomLeading)
            cornerHandle(.bottomTrailing, .bottomTrailing, .bottomTrailing)
        }
        // Keep the handles inside the rounded panel so the window's shadow follows the curve, not a rectangle.
        .clipShape(panelShape)
    }

    private func cornerHandle(_ handle: SettingsWindow.Handle, _ alignment: Alignment, _ position: FrameResizePosition) -> some View {
        grip(handle, position)
            .frame(width: 36, height: 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// Distance from the top-left corner kept free of resize grips: the close button (22–47 pt in) plus a margin.
    private static let closeButtonClearance: CGFloat = 64

    /// A strip along one edge, stopping short of the corners so the corner handles keep their area, and well short
    /// of the close button where the top and leading edges meet.
    private func edgeHandle(_ handle: SettingsWindow.Handle, _ alignment: Alignment, _ position: FrameResizePosition) -> some View {
        let vertical = handle == .leading || handle == .trailing
        let start = handle == .top || handle == .leading ? Self.closeButtonClearance : 36
        return grip(handle, position)
            .frame(width: vertical ? 8 : nil, height: vertical ? nil : 8)
            .padding(vertical ? .top : .leading, start)
            .padding(vertical ? .bottom : .trailing, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func grip(_ handle: SettingsWindow.Handle, _ position: FrameResizePosition) -> some View {
        // Clear: the glass behind already makes these spots clickable, and a fill would show at the corners.
        Color.clear
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: position))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in resize.update(handle) }
                .onEnded { _ in resize.end() })
            .accessibilityHidden(true)
    }

    // MARK: Sections

    // Just the centered logo; it carries the panel's name for VoiceOver since there's no visible title.
    private var header: some View {
        SquiddLogo(primary: store.logoPrimaryColor, highlight: store.logoHighlightColor)
            .frame(width: 52, height: 53)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Squidd Settings")
    }

    private var spotifyNote: String? {
        store.spotify.message ?? (store.spotify.hasSession ? store.playback.message : nil)
    }

    // Preserve the field layout, then center its visible bounds within the panel.
    private var spotifyID: some View {
        let height: CGFloat = spotifyNote == nil ? 56 : 84
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                Image("Spotify-Logo").resizable().frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("Spotify").font(SettingsStyle.font(11.25))
            }
            .frame(width: 60)
            .place(x: 62, y: 10.8)

            TextField("", text: $clientID, prompt: Text("Spotify Client ID").foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(SettingsStyle.font(10))
                .autocorrectionDisabled()
                .onSubmit { _ = store.spotify.saveClientID(clientID) }
                .padding(.horizontal, 12)
                .frame(width: 246, height: 29)
                .background(SettingsStyle.field, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel("Spotify Client ID")
                .accessibilityIdentifier("spotifyClientID")
                .place(x: 131.5, y: 0)
            InfoButton(text: "Paste the Client ID from your Spotify app, then click Save ID. You'll find it in the Developer Dashboard.\n\nDevelopment apps need a Premium app owner, and your Spotify account must be on the app's allowed-user list.")
                .place(x: 395, centerY: 14.5, height: 16)

            HStack(spacing: 0) {
                Button("Save ID") { _ = store.spotify.saveClientID(clientID) }
                    .buttonStyle(PillStyle(fill: SettingsStyle.gray, width: 40))
                    .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines) == store.spotify.clientID)
                Spacer(minLength: 8)
                Text(statusText).font(SettingsStyle.font(7.5, .regular)).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("spotifyConnectionStatus")
                Spacer(minLength: 8)
                Button { NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!) } label: {
                    Text("Developer Dashboard").font(SettingsStyle.font(8.5)).foregroundStyle(SettingsStyle.link)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
            .frame(width: 245.5)
            .place(x: 131.5, centerY: 46)

            if let note = spotifyNote {
                Text(note).font(SettingsStyle.font(8, .regular)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2).textSelection(.enabled)
                    .frame(width: 246, alignment: .leading)
                    .place(x: 131.5, y: 63)
            }
        }
        .frame(width: Self.columnWidth, height: height, alignment: .topLeading)
        .offset(x: -62)
        .frame(width: Self.contentWidth, height: height, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    private var spotifyConnect: some View {
        centeredColumn(spacing: 0) {
            HStack(spacing: 0) {
                Text(SpotifyAuth.redirectURI).font(SettingsStyle.font(8.75)).lineLimit(1).textSelection(.enabled)
                space(10)
                Button(action: copyRedirect) {
                    Image(systemName: copiedRedirect ? "checkmark" : "square.on.square").font(SettingsStyle.font(12))
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy Spotify redirect URI")
                space(12.8)
                connectButton
                space(16.6)
                Button("Disconnect") { store.spotify.disconnect() }
                    .buttonStyle(PillStyle(fill: SettingsStyle.gray, width: 59))
                space(12)
                InfoButton(text: "Register this redirect URI in your Spotify app. Copy puts it on the clipboard.\n\nMusic plays in Spotify on your active device; Squidd shows and controls that playback.\n\nDisconnect removes this Mac's saved login. You can also remove access at spotify.com/account/apps.")
            }
            .frame(height: 18)
        }
    }

    @ViewBuilder private var connectButton: some View {
        if store.spotify.state == .connecting {
            Button("Cancel") { store.spotify.cancelLogin() }
                .buttonStyle(PillStyle(fill: SettingsStyle.gray, width: 59))
                .accessibilityLabel("Cancel Spotify login")
        } else {
            Button(store.spotify.hasSession ? "Reconnect" : "Connect") {
                guard store.spotify.saveClientID(clientID) else { return }
                store.selectPreview(.off)
                store.spotify.connect()
            }
            .buttonStyle(PillStyle(fill: SettingsStyle.blue, width: 59))
        }
    }

    private var statusText: String {
        store.spotify.state == .disconnected ? "Not Connected to Spotify" : store.spotify.status
    }

    private var appearance: some View {
        centeredColumn(spacing: 14) {
            Text("Appearance").font(SettingsStyle.font(10, .semibold))
            HStack(spacing: 0) {
                Text("Logo").font(SettingsStyle.font(9, .semibold))
                space(10)
                logoSwatch("Primary", store.logoPrimaryColor) { store.logoPrimaryHex = $0.hexString }
                space(8)
                logoSwatch("Highlight", store.logoHighlightColor) { store.logoHighlightHex = $0.hexString }
                space(8)
                logoSwatch("Circle", store.logoCircleColor) { store.logoCircleHex = $0.hexString }
                    .opacity(store.showLogoCircle ? 1 : 0.45)
                    .disabled(!store.showLogoCircle)
                space(10)
                Button("Reset") { store.resetLogoColors() }
                    .buttonStyle(PillStyle(fill: SettingsStyle.red, width: 39.5))
                    .accessibilityLabel("Reset logo colors")
                    .shown(!store.logoIsDefault)
                space(12)
                InfoButton(text: "Colors of the Squidd logo on the launcher pill and at the top of Settings. Primary is the headband and ear cups, Highlight the tentacles, and Circle the background behind the logo on the pill.")
            }
            .frame(height: 25)
            Toggle("Show circle behind pill logo", isOn: $store.showLogoCircle)
                .toggleStyle(SquareCheckboxStyle())
                .font(SettingsStyle.font(8.8))
                .frame(height: 15)
            HStack(spacing: 0) {
                appearancePill(.automatic)
                space(8)
                appearancePill(.light)
                space(8)
                appearancePill(.dark)
                space(12)
                InfoButton(text: "Light is the clear glass. Dark is a deeper version that stays readable over bright windows and web pages.\n\nAutomatic follows System Settings › Appearance.")
            }
            .frame(height: 18)
        }
    }

    private func logoSwatch(_ label: String, _ color: Color, _ onChange: @escaping (Color) -> Void) -> some View {
        HStack(spacing: 0) {
            Text(label).font(SettingsStyle.font(9))
            space(8)
            ColorSwatch(color: color, label: "Logo \(label.lowercased())", onChange: onChange)
        }
    }

    private func appearancePill(_ option: WidgetAppearance) -> some View {
        let selected = store.widgetAppearance == option
        return Button(option.rawValue) { store.widgetAppearance = option }
            .buttonStyle(PillStyle(fill: selected ? SettingsStyle.blue : SettingsStyle.gray, width: 59))
            .accessibilityLabel("\(option.rawValue) appearance")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var pillArtwork: some View {
        centeredColumn(spacing: 10) {
            Toggle("Show album cover in pill", isOn: $store.showPillArtwork)
                .toggleStyle(SquareCheckboxStyle())
                .font(SettingsStyle.font(8.8))
                .frame(height: 15)
            Toggle("Show mascot in pill", isOn: $store.showMascot)
                .toggleStyle(SquareCheckboxStyle())
                .font(SettingsStyle.font(8.8))
                .frame(height: 15)
        }
    }

    private var mascot: some View {
        centeredColumn(spacing: 16) {
            Text("Mascot").font(SettingsStyle.font(10, .semibold))
            HStack(spacing: 0) {
                mascotPreview.frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 6))
                space(24.1)
                Button("Choose GIF or Image…") { pickMascot() }
                    .buttonStyle(PillStyle(fill: SettingsStyle.gray, width: 103.5))
                space(24.2)
                // Keeps its slot when hidden so the row doesn't shift.
                Button("Remove") { store.resetCustomMascot() }
                    .buttonStyle(PillStyle(fill: SettingsStyle.red, width: 39.5))
                    .accessibilityLabel("Remove mascot")
                    .shown(store.customMascotPath != nil)
                space(30.4)
                InfoButton(text: "Shown on the launcher next to the album art. Choose a GIF or an image.\n\nThe Squidd logo always stays; remove the mascot to show just the logo and album art.")
            }
            .frame(height: 28)
        }
    }

    private var accent: some View {
        centeredColumn(spacing: 19) {
            Text("Pill Accent").font(SettingsStyle.font(10, .semibold))
            HStack(spacing: 0) {
                Text("Primary").font(SettingsStyle.font(9))
                space(10.6)
                ColorSwatch(color: store.rimPrimaryColor, label: "Primary") {
                    store.setRimColors(primary: $0, accent: store.rimAccentColor)
                }
                space(10.5)
                Text("Highlight").font(SettingsStyle.font(9))
                space(10.6)
                ColorSwatch(color: store.rimAccentColor, label: "Highlight") {
                    store.setRimColors(primary: store.rimPrimaryColor, accent: $0)
                }
                space(23)
                Button("Reset") { store.resetRimColors() }
                    .buttonStyle(PillStyle(fill: SettingsStyle.red, width: 39.5))
                    .accessibilityLabel("Reset pill accent colors")
                    .shown(!store.rimIsDefault)
                space(30.4)
                InfoButton(text: "Colors of the glowing ring around the launcher pill while music plays. Click a square to pick a color.")
            }
            .frame(height: 25)
        }
    }

    private var outline: some View {
        centeredColumn(spacing: 0) {
            Toggle("Show dashed outline around player", isOn: $store.showCardOutline)
                .toggleStyle(SquareCheckboxStyle())
                .font(SettingsStyle.font(8.8))
                .frame(height: 15)
        }
    }

    private var shortcuts: some View {
        let errors = store.shortcutErrors + [store.preferenceError].compactMap { $0 }
        return centeredColumn(spacing: 0) {
            Text("Global Shortcuts").font(SettingsStyle.font(10, .semibold))
            Color.clear.frame(width: 1, height: 14)
            HStack(spacing: 28.7) {
                Text("⌘/").font(SettingsStyle.font(13))
                Text("shows or hides the player").font(SettingsStyle.font(9, .regular))
            }
            .frame(height: 18)
            Color.clear.frame(width: 1, height: 10.7)
            HStack(spacing: 0) {
                Text("⌘ ↑ ← ↓ →").font(SettingsStyle.font(13))
                space(18)
                Text("move the player up, left, down, and right").font(SettingsStyle.font(9, .regular))
                space(5)
                InfoButton(text: "Drag the launcher to move it. Drag any card corner to resize. Right-click either panel for its menu.")
            }
            .frame(height: 18)
            ForEach(errors, id: \.self) { error in
                Text(error).font(SettingsStyle.font(8, .regular)).foregroundStyle(SettingsStyle.errorText)
                    .padding(.top, 4)
            }
        }
    }

    private var mascotPreview: some View {
        Group {
            if let url = store.customMascotURL, let image = firstFrame(of: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image("Squidd-SI").renderingMode(.template).resizable().scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func copyRedirect() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SpotifyAuth.redirectURI, forType: .string)
        copiedRedirect = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedRedirect = false
        }
    }

    private func firstFrame(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    private func pickMascot() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { store.setCustomMascot(from: url) }
    }
}

private enum SettingsStyle {
    static let cornerRadius: CGFloat = 40
    static let panel = Color(white: 0.04)
    // Translucent white rather than solid grey: matches the design over black and stays visible over glass.
    static let field = Color.white.opacity(0.12)
    static let gray = Color.white.opacity(0.15)
    static let checkbox = Color.white.opacity(0.3)
    static let blue = Color(red: 0.29, green: 0.66, blue: 1.0)
    static let red = Color(red: 0.70, green: 0.13, blue: 0.12)
    static let link = Color(red: 0.25, green: 0.63, blue: 1.0)
    static let errorText = Color(red: 1.0, green: 0.42, blue: 0.40)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight) }
}

private extension View {
    /// Top-leading corner at (x, y) within a design-positioned block.
    func place(x: CGFloat, y: CGFloat) -> some View { offset(x: x, y: y) }

    /// Leading edge at x, vertically centered on centerY, within a design-positioned block.
    func place(x: CGFloat, centerY: CGFloat, height: CGFloat = 18) -> some View {
        frame(height: height).offset(x: x, y: centerY - height / 2)
    }

    /// Hides a control but keeps its space, so neighbouring controls don't move.
    func shown(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0).disabled(!visible).accessibilityHidden(!visible)
    }
}

private struct PillStyle: ButtonStyle {
    var fill: Color
    var width: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsStyle.font(7.75))
            .lineLimit(1)
            .foregroundStyle(.white)
            .frame(width: width, height: 18)
            .background(fill, in: Capsule())
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

private struct SquareCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 9.5) {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(configuration.isOn ? SettingsStyle.blue : SettingsStyle.checkbox)
                    .frame(width: 15, height: 15)
                    .overlay {
                        if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold)) }
                    }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

// Shows its note on hover; a click pins it open until the popover is dismissed.
private struct InfoButton: View {
    var text: String
    @State private var hovering = false
    @State private var pinned = false

    var body: some View {
        Button { pinned.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 11, weight: .medium))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: Binding(get: { hovering || pinned }, set: { if !$0 { hovering = false; pinned = false } }),
                 arrowEdge: .bottom) {
            Text(text).font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 240, alignment: .leading)
                .padding(12)
        }
        .accessibilityLabel("More info")
        .accessibilityHint(text)
    }
}

private struct ColorSwatch: View {
    var color: Color
    var label: String
    var onChange: (Color) -> Void

    var body: some View {
        Button { ColorPanelBridge.shared.open(initial: color, onChange: onChange) } label: {
            RoundedRectangle(cornerRadius: 4).fill(color)
                .frame(width: 25, height: 25)
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) color")
    }
}

// Routes the shared color panel to whichever swatch opened it last.
private final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((Color) -> Void)?

    func open(initial: Color, onChange: @escaping (Color) -> Void) {
        let panel = NSColorPanel.shared
        // Detach first so setting the starting color isn't reported to the previous swatch.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.color = NSColor(initial)
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) { onChange?(Color(nsColor: sender.color)) }
}
