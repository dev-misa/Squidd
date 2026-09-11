import SwiftUI
import ServiceManagement
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var store: AppStore
    var close: () -> Void
    @State private var clientID = ""
    @State private var copiedRedirect = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Squidd").font(.title2.bold())
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            spotifySetup
            Divider()
            mascotSetup
            Divider()
            ringSetup
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show dashed outline around player", isOn: $store.showCardOutline)
                Text("The dashed border drawn around the player card.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Playback preview").font(.headline)
                Picker("Preview", selection: Binding(get: { store.preview }, set: { store.selectPreview($0) })) {
                    ForEach(PreviewState.allCases) { Text($0.rawValue).tag($0) }
                }
                Text("Sample data only. No music plays and no Spotify commands are sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Global shortcuts").font(.headline)
                Text("⌘/  Show or hide player\n⌘⌃W / A / S / D  Move up / left / down / right")
                    .font(.callout)
                ForEach(store.shortcutErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            }
            HStack {
                VStack(alignment: .leading) {
                    Text("Launch at Login").font(.headline)
                    Text(store.loginDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.loginStatus == .enabled ? "Disable" : "Enable") { store.toggleLogin() }
            }
            if let error = store.preferenceError { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Drag the launcher to move. Drag any card corner to resize. Right-click either panel for its menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 440)
        }
        .frame(width: 440, height: 650)
        .onAppear { clientID = store.spotify.clientID }
    }

    private var spotifySetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spotify").font(.headline)
            Text(store.spotify.status).font(.callout)
                .accessibilityIdentifier("spotifyConnectionStatus")
            TextField("Spotify Client ID", text: $clientID)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .accessibilityIdentifier("spotifyClientID")
            HStack {
                Button("Save Client ID") { _ = store.spotify.saveClientID(clientID) }
                    .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines) == store.spotify.clientID)
                Link("Developer Dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
            }
            Text("Register this redirect URI in your Spotify app:")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(SpotifyAuth.redirectURI).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button(copiedRedirect ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SpotifyAuth.redirectURI, forType: .string)
                    copiedRedirect = true
                }.accessibilityLabel("Copy Spotify redirect URI")
            }
            HStack {
                if store.spotify.state == .connecting {
                    ProgressView().controlSize(.small)
                    Button("Cancel Login") { store.spotify.cancelLogin() }
                } else {
                    Button(store.spotify.hasSession ? "Reconnect Spotify" : "Connect Spotify") {
                        guard store.spotify.saveClientID(clientID) else { return }
                        store.selectPreview(.off)
                        store.spotify.connect()
                    }.buttonStyle(.borderedProminent)
                    Button("Disconnect") { store.spotify.disconnect() }
                }
            }
            if let message = store.spotify.message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Development apps require a Premium app owner and your Spotify account on the app’s allowed-user list.")
                .font(.caption).foregroundStyle(.secondary)
            if store.spotify.hasSession {
                Text(store.playback.message ?? store.playback.status).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Spotify") { store.openSpotify() }
                    Button("Retry Playback") { store.playback.retry() }.disabled(!store.playback.canRetry)
                }
            }
            Text("Music plays in Spotify on your active device. This widget displays and controls that playback.")
                .font(.caption).foregroundStyle(.secondary)
            if store.spotify.hasSession {
                Text("Disconnect removes this Mac’s saved login. Account access can also be removed at spotify.com/account/apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var mascotSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mascot").font(.headline)
            HStack(spacing: 10) {
                mascotPreview.frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mascot (GIF or image)").font(.callout)
                    HStack {
                        Button("Choose GIF or Image…") { pickMascot() }
                        if store.customMascotPath != nil { Button("Remove") { store.resetCustomMascot() } }
                    }
                }
            }
            Text("Shown on the launcher next to the album art. The Squidd logo always stays; leave this empty to show just the logo and album art.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var ringSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playback ring").font(.headline)
            HStack(spacing: 16) {
                ColorPicker("Primary", selection: Binding(
                    get: { store.rimPrimaryColor },
                    set: { store.setRimColors(primary: $0, accent: store.rimAccentColor) }
                ), supportsOpacity: false)
                ColorPicker("Highlight", selection: Binding(
                    get: { store.rimAccentColor },
                    set: { store.setRimColors(primary: store.rimPrimaryColor, accent: $0) }
                ), supportsOpacity: false)
                Spacer()
                if store.rimPrimaryHex != nil || store.rimAccentHex != nil {
                    Button("Reset") { store.resetRimColors() }
                }
            }
            Text("Colors of the glowing ring around the launcher while music plays.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var mascotPreview: some View {
        Group {
            if let url = store.customMascotURL, let image = firstFrame(of: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
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
