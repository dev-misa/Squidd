import AppKit
import CoreGraphics
import Foundation

@main
enum AppleMusicChecks {
    @MainActor static func main() async throws {
        try checkPlayerStateCodes()
        try checkPermissionMapping()
        try await checkPlaybackLifecycle()
        try await checkCommands()
        try await checkPermissionRefusal()
        try await checkSourceSelection()
        print("Apple Music checks passed: four-character state codes, permission mapping, not-running/idle/playing "
            + "states, artwork, commands with seek clamping and rollback, refused Automation, and source selection.")
    }

    // The sdef's `ePlS` enumerators, decoded from their four-character codes rather than hard-coded integers.
    static func checkPlayerStateCodes() throws {
        assert(AppleMusicPlayerState(raw: AppleMusicPlayerState.code("kPSP")) == .playing)
        assert(AppleMusicPlayerState(raw: AppleMusicPlayerState.code("kPSp")) == .paused)
        assert(AppleMusicPlayerState(raw: AppleMusicPlayerState.code("kPSS")) == .stopped)
        assert(AppleMusicPlayerState(raw: AppleMusicPlayerState.code("kPSF")) == .fastForwarding)
        assert(AppleMusicPlayerState(raw: AppleMusicPlayerState.code("kPSR")) == .rewinding)
        // 'kPSP' is 0x6B505350; a literal confirms the packing, not just the round trip.
        assert(AppleMusicPlayerState.code("kPSP") == 0x6B50_5350)
        assert(AppleMusicPlayerState(raw: 0) == .unknown)
        // Scrubbing counts as playing, so the progress bar keeps moving and the pause button stays correct.
        assert(AppleMusicPlayerState.fastForwarding.isPlaying && AppleMusicPlayerState.rewinding.isPlaying)
        assert(!AppleMusicPlayerState.paused.isPlaying && !AppleMusicPlayerState.unknown.isPlaying)
        assert(AppleMusicPlayerState(notification: "Playing") == .playing)
        assert(AppleMusicPlayerState(notification: "Paused") == .paused)
        assert(AppleMusicPlayerState(notification: "Stopped") == .stopped)
        assert(AppleMusicPlayerState(notification: "anything else") == .unknown)
    }

    static func checkPermissionMapping() throws {
        assert(AppleMusicPermission(status: noErr) == .granted)
        assert(AppleMusicPermission(status: -1743) == .denied)
        assert(AppleMusicPermission(status: -1744) == .notDetermined)
        assert(AppleMusicPermission(status: -600) == .musicNotRunning)
        assert(AppleMusicPermission(status: -609) == .musicNotRunning)
        assert(AppleMusicPermission(status: -12345) == .unknown(-12345))
    }

    @MainActor static func backend(_ music: FakeMusic) -> AppleMusicPlayback {
        // No notification centers: the checks drive the fake directly, and a distributed observer would outlive it.
        AppleMusicPlayback(music: music, pollInterval: 0.05, idlePollInterval: 0.05, boostInterval: 0.05,
                           notifications: nil, workspace: nil)
    }

    @MainActor static func settle(_ seconds: Double = 0.25) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func checkPlaybackLifecycle() async throws {
        let music = FakeMusic()
        music.artworkImage = solidImage()
        let playback = backend(music)
        await settle()

        // Music is not running: nothing to show, nothing to send, and this backend is not a candidate at all.
        assert(playback.state == .notRunning)
        assert(!playback.isAvailable && !playback.hasTrack && !playback.isPlaying)
        assert(!playback.permits(.play) && !playback.permits(.next) && !playback.permits(.seek(1)))
        assert(playback.title == "Nothing playing" && playback.duration == 0)

        // Running but with nothing loaded.
        music.status = AppleMusicStatus(isRunning: true, state: .stopped, position: 0, track: nil, responded: true)
        await settle()
        assert(playback.state == .idle && playback.isAvailable && !playback.hasTrack)
        assert(!playback.permits(.pause))

        // Playing.
        music.status = playingStatus()
        await settle()
        assert(playback.state == .playing && playback.isPlaying && playback.hasTrack)
        assert(playback.title == "Nautilus" && playback.artist == "Anna Meredith")
        assert(playback.duration == 200)
        assert(playback.elapsed >= 10 && playback.elapsed < 12)
        assert(playback.lastActiveAt != nil)
        assert(playback.permits(.play) && playback.permits(.next) && playback.permits(.seek(20)))
        assert(playback.artworkKey == "apple-music:ABC123")
        assert(playback.artwork != nil)
        assert(music.artworkRequests == ["ABC123"], "artwork is fetched once per track, not once per poll")

        // Each refresh adopts the position the Music app reports, so scrubbing inside Music is picked up.
        music.status = playingStatus(position: 90)
        await settle()
        assert(playback.elapsed >= 90 && playback.elapsed < 92, "got \(playback.elapsed)")

        // Between refreshes the bar is driven locally. Checked on a backend polling far too slowly to be the
        // cause, since the fake's position never moves on its own.
        let slowMusic = FakeMusic()
        slowMusic.status = playingStatus(position: 10)
        let slow = AppleMusicPlayback(music: slowMusic, pollInterval: 60, idlePollInterval: 60, boostInterval: 60,
                                      notifications: nil, workspace: nil)
        await settle()
        let ticked = slow.elapsed
        await settle(0.8)
        // Only that it moves: the 250 ms tick plus scheduling jitter makes an exact advance unreliable, and the
        // paused case below asserts exact equality, which is what distinguishes ticking from frozen.
        assert(slow.elapsed > ticked + 0.15, "the progress bar must tick between refreshes, got \(slow.elapsed)")

        // Paused, the same backend stops moving.
        slowMusic.status = playingStatus(position: 30, playing: false)
        slow.boost(for: 0.1)
        await settle()
        assert(slow.state == .paused && !slow.isPlaying)
        let paused = slow.elapsed
        await settle(0.5)
        assert(slow.elapsed == paused, "a paused track must not keep ticking")
        slow.stop()

        // Paused in the fast backend too, which is the state the rest of this check continues from.
        music.status = playingStatus(position: 30, playing: false)
        await settle()
        assert(playback.state == .paused && !playback.isPlaying)

        // A new track replaces the artwork; the old one is not left on screen.
        music.status = playingStatus(title: "Taken", identity: "XYZ789", duration: 120, position: 0)
        await settle()
        assert(playback.title == "Taken" && playback.artworkKey == "apple-music:XYZ789")
        assert(music.artworkRequests == ["ABC123", "XYZ789"])

        // Preview mode and sleep both stand the backend down, and leaving them brings it back.
        playback.setPreviewing(true)
        await settle()
        assert(!playback.permits(.play) && playback.state == .notRunning)
        playback.setPreviewing(false)
        await settle()
        assert(playback.state == .playing)
        playback.setSuspended(true)
        await settle()
        assert(!playback.permits(.play))
        playback.setSuspended(false)
        await settle()
        assert(playback.state == .playing)

        // Music quitting clears the card rather than freezing the last track on it.
        music.status = AppleMusicStatus()
        await settle()
        assert(playback.state == .notRunning && !playback.hasTrack && playback.elapsed == 0)
        assert(playback.artwork == nil)
        playback.stop()
    }

    static func checkCommands() async throws {
        let music = FakeMusic()
        let playback = backend(music)
        music.status = playingStatus(duration: 200, position: 10)
        await settle()

        playback.send(.next)
        await settle()
        assert(music.sent == [.next])

        playback.send(.pause)
        await settle()
        assert(music.sent == [.next, .pause])

        // Seeking past the end is clamped to the track's duration before it leaves the app.
        music.clearSent()
        playback.send(.seek(9_999))
        await settle()
        assert(music.sent == [.seek(200)], "seek past the end must clamp to duration, got \(music.sent)")

        // A non-finite seek is dropped rather than sent.
        music.clearSent()
        playback.send(.seek(.nan))
        await settle()
        assert(music.sent.isEmpty)

        // A failing command puts the optimistic seek back where it was and explains itself.
        music.status = playingStatus(duration: 200, position: 50, playing: false)
        await settle()
        let before = playback.elapsed
        music.failure = .notPermitted
        playback.send(.seek(120))
        await settle()
        assert(playback.message != nil, "a failed command has to say so")
        assert(abs(playback.elapsed - before) < 2, "a failed seek must roll back, got \(playback.elapsed)")
        playback.stop()
    }

    static func checkPermissionRefusal() async throws {
        let music = FakeMusic()
        let playback = backend(music)
        // Music is running but every Apple event is refused: `responded` stays false.
        music.status = AppleMusicStatus(isRunning: true, state: .unknown, position: nil, track: nil, responded: false)
        music.permissionAnswer = .denied
        await settle()
        assert(playback.state == .denied)
        assert(playback.isAvailable, "the backend is still reachable; only control is blocked")
        assert(!playback.canControl)
        assert(!playback.permits(.play) && !playback.permits(.next))

        music.permissionAnswer = .notDetermined
        await settle()
        assert(playback.state == .needsPermission)

        // Granting it lets the normal path resume.
        music.permissionAnswer = .granted
        music.status = playingStatus()
        await settle()
        assert(playback.state == .playing && playback.canControl && playback.permits(.next))
        playback.stop()
    }

    static func checkSourceSelection() async throws {
        let defaults = UserDefaults(suiteName: "squidd.apple-music.checks")!
        defaults.removePersistentDomain(forName: "squidd.apple-music.checks")
        let music = FakeMusic()
        let store = AppStore(defaults: defaults, appleMusic: backend(music))
        await settle()

        // With no Spotify session and Music not running, neither backend is available and nothing changes hands.
        assert(store.sourcePreference == nil)
        assert(!store.appleMusic.isAvailable && !store.playback.isAvailable)

        // Music starts playing and becomes the only available backend, so the widget follows it.
        music.status = playingStatus()
        await settle()
        assert(store.activeKind == .appleMusic, "automatic mode should follow the only service that is playing")
        assert(store.title == "Nautilus" && store.artist == "Anna Meredith")
        assert(store.isPlaying && store.canControl && store.canSeek)
        assert(store.shownDuration == 200)
        assert(store.artworkKey == "apple-music:ABC123")

        // Transport goes to the active backend.
        store.skip()
        await settle()
        assert(music.sent.contains(.next))

        // Pinning Spotify overrides the choice even though it has nothing playing, and survives a reload.
        store.sourcePreference = .spotify
        await settle()
        assert(store.activeKind == .spotify)
        assert(store.title == "Nothing playing", "a pinned, unconnected Spotify must not show Music's track")
        assert(defaults.string(forKey: "musicSource") == "Spotify")
        let reloaded = AppStore(defaults: defaults, appleMusic: backend(FakeMusic()))
        assert(reloaded.sourcePreference == .spotify && reloaded.activeKind == .spotify)
        reloaded.stop()

        // Back to automatic, and Music takes the card again.
        store.sourcePreference = nil
        await settle()
        assert(store.activeKind == .appleMusic)
        assert(defaults.string(forKey: "musicSource") == AppStore.automaticSource)

        // Pausing does not hand the widget away: the paused track is still the thing worth showing.
        music.status = playingStatus(playing: false)
        await settle()
        assert(store.activeKind == .appleMusic && !store.isPlaying)

        // A streamed Apple Music track reports no duration and no position. The card must still show it, but
        // without a scrubber frozen at zero, and seeking has to stay refused.
        music.status = AppleMusicStatus(isRunning: true, state: .playing, position: nil,
                                        track: AppleMusicTrack(identity: "stream-1", title: "BESO DE ESOS",
                                                               artist: "ALOISIO", album: "", duration: 0),
                                        responded: true)
        await settle()
        assert(store.isPlaying && store.title == "BESO DE ESOS")
        assert(store.shownDuration == 0 && store.elapsed == 0)
        assert(!store.showsTimeline, "a track with no length must not show a timeline")
        assert(!store.canSeek && !store.appleMusic.permits(.seek(10)))
        // Transport still works; only the timeline is missing.
        assert(store.canControl && store.appleMusic.permits(.next))
        // The clock must not be left running against a zero duration.
        await settle(0.4)
        assert(store.elapsed == 0)

        // A track that does report a length gets its timeline back.
        music.status = playingStatus(duration: 180, position: 20)
        await settle()
        assert(store.showsTimeline && store.shownDuration == 180 && store.canSeek)

        store.stop()
        defaults.removePersistentDomain(forName: "squidd.apple-music.checks")
    }
}
