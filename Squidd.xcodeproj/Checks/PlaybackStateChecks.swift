import Foundation

@main
enum PlaybackStateChecks {
    @MainActor static func main() async throws {
        let store = AppStore()
        assert(!store.canControl && !store.isPlaying)
        store.seek(to: 100)
        assert(store.elapsed == 0)
        store.selectPreview(.playing)
        try await Task.sleep(for: .milliseconds(600))
        assert(store.elapsed > 0 && store.elapsed < 2)
        store.togglePlayback()
        let paused = store.elapsed
        try await Task.sleep(for: .milliseconds(350))
        assert(store.elapsed == paused)
        store.seek(to: -100)
        assert(store.elapsed == 0)
        store.seek(to: 9999)
        assert(store.elapsed == store.duration)
        store.skip()
        assert(store.sampleIndex == 1 && store.elapsed == 0)
        assert(store.artist.localizedCaseInsensitiveContains("sabrina carpenter"))
        store.togglePlayback()
        store.sleeping = true
        store.reconcileClock()
        let sleeping = store.elapsed
        try await Task.sleep(for: .milliseconds(350))
        assert(store.elapsed == sleeping)
        store.sleeping = false
        store.reconcileClock()
        try await Task.sleep(for: .milliseconds(350))
        assert(store.elapsed > sleeping)
        store.selectPreview(.off)
        try await Task.sleep(for: .milliseconds(350))
        assert(store.elapsed == 0 && !store.canControl && store.shownDuration == 0)
        store.stop()
        print("Playback state checks passed: disconnected guard, progress tick, pause, seek bounds, track changes, sleep/wake, and preview shutdown.")
    }
}
