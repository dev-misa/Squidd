import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class FloatingPanel: NSPanel {
    init<Content: View>(size: CGSize, rootView: Content) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Keep the floating widget visually active without changing keyboard focus.
        let hosting = NSHostingView(rootView: rootView
            .environment(\.appearsActive, true)
            .environment(\.materialActiveAppearance, .active))
        // A plain container lets PanelInteraction sit above the hosting view as a sibling;
        // AppKit doesn't support adding subviews to an NSHostingView.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container
    }
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
    // AppKit asks this separate appearance hook when rendering window glass.
    // Keep actual isKeyWindow/isMainWindow truthful for focus and event routing.
    // This selector is undocumented; recheck inactive glass on macOS updates.
    @objc dynamic func hasKeyAppearance() -> Bool { true }

}

private struct SavedPlacement: Codable {
    var screenID: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var valid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width > 0 && height > 0 }
}

@MainActor
final class WindowCoordinator: NSObject {
    let store: AppStore
    let card: FloatingPanel
    let launcher: FloatingPanel
    private let hotKeys = GlobalHotKeys()
    private var settings: NSWindow?
    private var originalFrame = CGRect.zero
    private var pointerOrigin = CGPoint.zero
    private var dragging = false
    private var interacting = false
    private var resizeCorner: CardCorner?
    private var saveTask: Task<Void, Never>?
    private var pointerTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let defaults = UserDefaults.standard

    init(store: AppStore) {
        self.store = store
        card = FloatingPanel(size: WidgetMetrics.card, rootView: ContentView(store: store))
        launcher = FloatingPanel(size: WidgetMetrics.launcher, rootView: LauncherView(store: store))
        super.init()
        card.acceptsKeyboard = true
        card.becomesKeyOnlyIfNeeded = true
        addInteraction(to: launcher, launcher: true)
        addInteraction(to: card, launcher: false)
        restore()
        hotKeys.action = { [weak self] id in
            guard let self else { return }
            if id == 0 { self.toggleCard(); return }
            let offsets: [UInt32: CGPoint] = [1: CGPoint(x: 0, y: 20), 2: CGPoint(x: -20, y: 0), 3: CGPoint(x: 0, y: -20), 4: CGPoint(x: 20, y: 0)]
            guard let delta = offsets[id] else { return }
            var frame = self.card.frame
            frame.origin.x += delta.x; frame.origin.y += delta.y
            self.place(frame, screen: self.bestScreen(for: frame))
        }
        store.shortcutErrors = hotKeys.register()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverDisplay() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.sleeping = true; self?.store.reconcileClock()
                self?.store.setSuspended(true)
                self?.store.spotify.setSuspended(true)
                self?.pointerTimer?.invalidate(); self?.pointerTimer = nil
                self?.savePlacement()
            }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.sleeping = false; self?.store.reconcileClock()
                self?.store.spotify.setSuspended(false)
                self?.store.setSuspended(false)
                self?.store.boostSources()
                self?.recoverDisplay(); self?.startPointerTracking()
            }
        })
        // Either player coming to the front usually means playback is about to change, so catch it quickly.
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let kind = MusicSourceKind.allCases.first(where: { $0.bundleIdentifier == app?.bundleIdentifier })
                else { return }
                self?.store.boost(kind)
            }
        })
    }

    private func addInteraction(to panel: FloatingPanel, launcher: Bool) {
        let interaction = PanelInteraction(frame: NSRect(origin: .zero, size: panel.frame.size))
        interaction.autoresizingMask = [.width, .height]
        interaction.coordinator = self
        interaction.isLauncher = launcher
        panel.contentView?.addSubview(interaction)
    }

    func show() {
        card.orderFrontRegardless(); launcher.orderFrontRegardless()
        store.cardVisible = true
        startPointerTracking()
    }

    func toggleCard() {
        store.cardVisible.toggle()
        if store.cardVisible {
            card.orderFrontRegardless()
            store.boostSources()
        } else { card.orderOut(nil) }
    }

    func resetPosition() {
        guard let screen = NSScreen.main else { return }
        var frame = card.frame
        frame.origin = CGPoint(x: screen.visibleFrame.midX - frame.width / 2,
                               y: screen.visibleFrame.midY - (frame.height + WidgetGeometry.launcherAllowance) / 2)
        place(frame, screen: screen)
    }

    func saveDefaultSize() {
        defaults.set([card.frame.width, card.frame.height], forKey: "defaultPanelSize")
    }

    func resetSize() {
        var frame = card.frame
        frame.size = defaultSize
        place(frame, screen: bestScreen(for: card.frame))
    }

    private var defaultSize: CGSize {
        if let size = defaults.array(forKey: "defaultPanelSize") as? [Double], size.count == 2,
           size.allSatisfy({ $0.isFinite && $0 > 0 }) { return CGSize(width: size[0], height: size[1]) }
        return WidgetMetrics.card
    }

    func beginDrag(corner: CardCorner? = nil) {
        pointerOrigin = NSEvent.mouseLocation
        originalFrame = card.frame
        resizeCorner = corner
        dragging = false
        interacting = true
        card.ignoresMouseEvents = false; launcher.ignoresMouseEvents = false
    }

    func updateDrag() {
        let pointer = NSEvent.mouseLocation
        let delta = CGPoint(x: pointer.x - pointerOrigin.x, y: pointer.y - pointerOrigin.y)
        dragging = dragging || abs(delta.x) > 4 || abs(delta.y) > 4
        if let corner = resizeCorner {
            let screen = bestScreen(for: originalFrame)
            guard let screen else { return }
            place(WidgetGeometry.resize(originalFrame, corner: corner, delta: delta, screen: screen.visibleFrame), screen: screen)
        } else if dragging {
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? bestScreen(for: card.frame)
            place(originalFrame.offsetBy(dx: delta.x, dy: delta.y), screen: screen)
        }
    }

    func endDrag() {
        if resizeCorner == nil && !dragging { toggleCard() }
        interacting = false; dragging = false; resizeCorner = nil
        scheduleSave()
    }

    private func place(_ frame: CGRect, screen: NSScreen?) {
        guard let screen else { return }
        card.setFrame(WidgetGeometry.fit(frame, in: screen.visibleFrame), display: true)
        launcher.setFrame(WidgetGeometry.launcher(for: card.frame), display: true)
        scheduleSave()
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.max {
            let a = $0.visibleFrame.intersection(frame), b = $1.visibleFrame.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        } ?? NSScreen.main
    }

    private func screenID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func restore() {
        if let data = defaults.data(forKey: "panelPlacement"),
           let saved = try? JSONDecoder().decode(SavedPlacement.self, from: data), saved.valid {
            if let screen = NSScreen.screens.first(where: { screenID($0) == saved.screenID }) {
                place(CGRect(x: screen.visibleFrame.minX + saved.x, y: screen.visibleFrame.minY + saved.y,
                             width: saved.width, height: saved.height), screen: screen)
            } else {
                card.setContentSize(CGSize(width: saved.width, height: saved.height))
                resetPosition()
            }
        } else {
            card.setContentSize(defaultSize)
            resetPosition()
        }
    }

    private func recoverDisplay() { place(card.frame, screen: bestScreen(for: card.frame)) }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.savePlacement()
        }
    }

    func savePlacement() {
        guard let screen = bestScreen(for: card.frame) else { return }
        let frame = card.frame
        let saved = SavedPlacement(screenID: screenID(screen), x: frame.minX - screen.visibleFrame.minX,
                                   y: frame.minY - screen.visibleFrame.minY, width: frame.width, height: frame.height)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "panelPlacement") }
    }

    // Position polling sees re-entry even while the transparent window ignores events.
    // No event tap, keystroke monitor, Accessibility, or screen-capture permission is used.
    private func startPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointerPassthrough() }
        }
        RunLoop.main.add(pointerTimer!, forMode: .common)
    }

    private func updatePointerPassthrough() {
        guard !interacting else { return }
        // The pill only fills part of its panel, and shrinks when there's no album art or mascot; anywhere outside it
        // belongs to whatever is behind the launcher.
        let pillWidth = WidgetMetrics.pillWidth(artwork: store.showsArtwork, mascot: store.customMascotURL != nil)
        let launcherRect = CGRect(origin: .zero, size: launcher.frame.size)
            .insetBy(dx: (launcher.frame.width - pillWidth) / 2, dy: (launcher.frame.height - WidgetMetrics.pillHeight) / 2)
        let cardRect = CGRect(origin: .zero, size: card.frame.size).insetBy(dx: 6, dy: 6)
        for (panel, rect, radius) in [(launcher, launcherRect, WidgetMetrics.pillHeight / 2), (card, cardRect, CGFloat(24))] where panel.isVisible {
            let point = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
            panel.ignoresMouseEvents = !NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).contains(point)
        }
    }

    func showSettings() {
        if settings == nil {
            let window = SettingsWindow(size: SettingsView.defaultSize)
            let resize = SettingsResize(update: { [weak window] in window?.resize(from: $0) },
                                        end: { [weak window] in window?.endResize() })
            window.contentView = NSHostingView(rootView: SettingsView(store: store, close: { [weak window] in window?.orderOut(nil) },
                                                                      resize: resize))
            // Reopen at the size and place the panel was left at.
            if !window.setFrameUsingName("SquiddSettingsFrame") { window.center() }
            window.setFrameAutosaveName("SquiddSettingsFrame")
            // A size saved before the minimum grew would cut content off; grow it back to the minimum.
            let saved = window.frame, minimum = SettingsView.minimumSize
            if saved.width < minimum.width || saved.height < minimum.height {
                let size = NSSize(width: max(saved.width, minimum.width), height: max(saved.height, minimum.height))
                window.setFrame(NSRect(x: saved.minX, y: saved.maxY - size.height, width: size.width, height: size.height), display: false)
            }
            settings = window
        }
        store.loginStatus = SMAppService.mainApp.status
        NSApp.activate(ignoringOtherApps: true)
        settings?.makeKeyAndOrderFront(nil)
        // The shadow follows the panel's rounded, transparent edges once it has drawn.
        settings?.invalidateShadow()
    }

    func openDataFolder() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Squidd", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Preferences remain in UserDefaults; export a readable snapshot for inspection.
            var snapshot: [String: Any] = ["inkOverrides": store.inkChoices]
            if let size = defaults.array(forKey: "defaultPanelSize") { snapshot["defaultPanelSize"] = size }
            if let placement = defaults.data(forKey: "panelPlacement"), let value = try? JSONSerialization.jsonObject(with: placement) { snapshot["panelPlacement"] = value }
            try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("preferences-snapshot.json"), options: .atomic)
            NSWorkspace.shared.open(directory)
        } catch { store.preferenceError = error.localizedDescription; showSettings() }
    }

    func stop() {
        saveTask?.cancel(); savePlacement()
        pointerTimer?.invalidate(); pointerTimer = nil
        hotKeys.stop(); store.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []; workspaceObservers = []
    }
}

@MainActor
final class PanelInteraction: NSView {
    weak var coordinator: WindowCoordinator?
    var isLauncher = false
    private var activeCorner: CardCorner?

    private func corner(at point: CGPoint) -> CardCorner? {
        CardCorner.allCases.first { cornerRect($0).contains(point) }
    }
    private func cornerRect(_ corner: CardCorner) -> CGRect {
        CGRect(x: corner.left ? 26 : bounds.width - 40, y: corner.top ? bounds.height - 40 : 26, width: 14, height: 14)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if isLauncher || corner(at: local) != nil || NSApp.currentEvent?.type == .rightMouseDown { return self }
        return nil
    }
    override func resetCursorRects() {
        if isLauncher {
            // Match the pill, which narrows when there's no album art or mascot.
            let width = coordinator.map { WidgetMetrics.pillWidth(artwork: $0.store.showsArtwork, mascot: $0.store.customMascotURL != nil) }
                ?? WidgetMetrics.pillWidth(artwork: true, mascot: true)
            addCursorRect(bounds.insetBy(dx: (bounds.width - width) / 2, dy: (bounds.height - WidgetMetrics.pillHeight) / 2),
                          cursor: .openHand)
        }
        else { for corner in CardCorner.allCases { addCursorRect(cornerRect(corner), cursor: .crosshair) } }
    }
    override func mouseDown(with event: NSEvent) {
        activeCorner = isLauncher ? nil : corner(at: convert(event.locationInWindow, from: nil))
        if isLauncher || activeCorner != nil { coordinator?.beginDrag(corner: activeCorner) }
    }
    override func mouseDragged(with event: NSEvent) { coordinator?.updateDrag() }
    override func mouseUp(with event: NSEvent) { coordinator?.endDrag(); activeCorner = nil }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if isLauncher {
            add("Show / Hide Player", #selector(toggle), to: menu)
            add("Settings…", #selector(settings), to: menu)
            add(coordinator?.store.activeKind == .appleMusic ? "Open Music" : "Open Spotify",
                #selector(openPlayer), to: menu)
            if coordinator?.store.spotify.state == .connecting {
                add("Cancel Spotify Login", #selector(cancelSpotify), to: menu)
            } else if coordinator?.store.spotify.hasSession == true {
                add("Disconnect Spotify", #selector(disconnectSpotify), to: menu)
            } else {
                add("Connect Spotify…", #selector(connectSpotify), to: menu)
            }
            menu.addItem(.separator())
            add("Set Current Size as Default", #selector(saveSize), to: menu)
            add("Reset Size", #selector(resetSize), to: menu)
            add("Reset Position", #selector(reset), to: menu)
            add("Open Data Folder", #selector(dataFolder), to: menu)
            let login = add("Launch at Login", #selector(login), to: menu)
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(.separator())
            add("Quit Squidd", #selector(quit), to: menu)
        } else {
            for (index, mode) in InkMode.allCases.enumerated() {
                let item = add(mode.rawValue, #selector(ink(_:)), to: menu)
                item.tag = index; item.state = coordinator?.store.ink == mode ? .on : .off
            }
            menu.addItem(.separator())
            add("Forget All Ink Choices", #selector(forgetInk), to: menu)
            menu.addItem(.separator())
            let outline = add("Show Dashed Outline", #selector(toggleOutline), to: menu)
            outline.state = coordinator?.store.showCardOutline == true ? .on : .off
        }
        return menu
    }
    @discardableResult private func add(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }
    @objc private func toggle() { coordinator?.toggleCard() }
    @objc private func connectSpotify() {
        coordinator?.showSettings()
        guard let auth = coordinator?.store.spotify, SpotifyAuth.validClientID(auth.clientID) else { return }
        auth.connect()
    }
    @objc private func openPlayer() { coordinator?.store.openActiveApp() }
    @objc private func disconnectSpotify() { coordinator?.store.spotify.disconnect() }
    @objc private func cancelSpotify() { coordinator?.store.spotify.cancelLogin() }
    @objc private func settings() { coordinator?.showSettings() }
    @objc private func saveSize() { coordinator?.saveDefaultSize() }
    @objc private func resetSize() { coordinator?.resetSize() }
    @objc private func reset() { coordinator?.resetPosition() }
    @objc private func dataFolder() { coordinator?.openDataFolder() }
    // The menu item's checkmark shows the state; Settings only opens to show a failure.
    @objc private func login() {
        coordinator?.store.toggleLogin()
        if coordinator?.store.preferenceError != nil { coordinator?.showSettings() }
    }
    @objc private func ink(_ sender: NSMenuItem) { coordinator?.store.setInk(InkMode.allCases[sender.tag]) }
    @objc private func forgetInk() { coordinator?.store.forgetInk() }
    @objc private func toggleOutline() { coordinator?.store.showCardOutline.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }
    override func accessibilityIsIgnored() -> Bool { !isLauncher }
    override func accessibilityRole() -> NSAccessibility.Role? { isLauncher ? .button : nil }
    override func accessibilityLabel() -> String? { isLauncher ? "Show or hide Squidd player. Drag to move." : nil }
    override func accessibilityPerformPress() -> Bool { guard isLauncher else { return false }; coordinator?.toggleCard(); return true }
}
