# Native rebuild progress

## Approved visual baseline

User approved the native layout on 2026-09-10. Preserve the clear Liquid Glass,
0.5-point white strokes at 50% opacity on both surfaces, and original dashed
outer card outline. Latest requested refinement: dashed outline is white at 85%
opacity; glass-only backing is rendered at 88% opacity, text backing at 6%,
and empty artwork backing at 3%. Foreground content remains fully opaque.
Visual acceptance of this refinement is pending. No title bars or traffic-light buttons on the panels.
Settings also hides the traffic lights and provides a Done button.

### Always-active glass appearance (2026-09-10)

The nonactivating panels never become key, so `.ultraThinMaterial` and
`.glassEffect` were rendering their darker inactive appearance whenever another
app held focus, and only brightening on click. `FloatingPanel` now wraps its
hosted root view with `.environment(\.appearsActive, true)` (forces
`glassEffect` active rendering) and `.environment(\.materialActiveAppearance,
.active)` (forces `Material` active rendering). Both keys are settable in the
macOS 26.5 SDK; Debug build succeeds. Focus is unchanged — still
`.nonactivatingPanel`, `canBecomeKey` gated by `acceptsKeyboard`.

Follow-up: the environment values alone did not remove the inactive look — the
`.glassEffect(.clear)` layer (dominant, opacity 0.88) is backed by
`NSGlassEffectView`, which on macOS 26 has **no** active-state override
(confirmed against the 26.5 SDK header: only `style`, `cornerRadius`,
`tintColor`, `contentView`). It follows the host window's key appearance, which
is why the card brightened only on click (card can become key) and the launcher
never did. `NSVisualEffectView.state = .active` exists but would mean abandoning
Liquid Glass for the approved baseline. The initial `isKeyWindow` / `isMainWindow` overrides did not fix this:
user screenshots confirmed the glass still changed on click-away. The earlier
claim that these getters affect drawing only was not established and is withdrawn.

Follow-up (2026-09-10, 19:21): removed those overrides so actual key/main status
remains truthful. `FloatingPanel` now implements the undocumented Objective-C
`hasKeyAppearance` selector, returning true for both panels. This targets AppKit's
separate appearance query; nonactivating style and keyboard eligibility remain
unchanged. Existing SwiftUI clear Liquid Glass and accessibility fallbacks remain.
Prior art for this appearance hook: Chromium NativeWidgetMacNSWindow,
https://chromium.googlesource.com/experimental/chromium/src/+/refs/tags/73.0.3664.1/ui/views_bridge_mac/native_widget_mac_nswindow.mm
This is a private API compatibility dependency and needs verification after OS
updates. Full unsigned Debug build passed; app restarted in the background.
User confirmed the visual result: “perfect, now the visual is set.”
The clear Liquid Glass baseline is accepted; preserve this appearance hook.
Phase1 staging copy synced.


Built on macOS 26.6.2 with Xcode 26.6 (macOS 26.5 SDK), targeting macOS 26.0+.
Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; the system developer
directory is unchanged. Observation macros require a build outside the agent sandbox.

## Offline interaction milestone implemented

- Two retained nonactivating floating panels; player 304 × 180 visible, pill 141 × 52.
- Launcher logo click opens or closes Settings (⌘/ shows or hides the card); group drag uses screen coordinates and a four-point threshold.
- Four 14-point corner handles, opposite-corner anchoring, minimum visible size 270 × 158,
  and per-display clamping. Sizes/fonts/art do not uniformly scale.
- Position and current size saved after a 400 ms debounce and on exit/sleep; explicit
  default-size preference is separate. Restore saves screen ID and relative position.
- Display-change recovery and saved-size preservation when the original display is absent.
- Pointer-position polling at 30 Hz makes transparent panel margins ignore mouse events
  and detects re-entry without event taps or screen recording. Paused during sleep;
  pinned during drag/resize. Rapid re-entry and Spaces still need hands-on checks.
- Carbon global shortcuts: Command+/ and Command+arrow keys (up, left, down, right). Registration failures
  appear in Settings. Unregistered on shutdown.
- Launcher and menu bar actions, native Settings, login-item service with actual status,
  and per-artwork ink choices (preview uses isolated artwork keys).
- Open Data Folder exports a readable preferences snapshot; authoritative settings use
  UserDefaults. No credentials are stored in this snapshot.
- Explicit playback preview defaults off; sample artwork and metadata are clearly labeled.
- Preview transport, 180 ms pressed feedback, seek drag/accessibility/arrow-key adjustment,
  interpolated progress, GIF frame delays and pause retention, rotating rim, particles,
  and sample Sabrina kiss variant. Preview generates no Spotify traffic or audio.
- Reduce Motion suppresses decorative animation; Reduce Transparency/Increase Contrast
  retain the semantic opaque backing. Card animations suspend when hidden or sleeping.

## Validation

- Full unsigned Debug Xcode build passed; app reopened.
- `Checks/GeometryChecks.swift`: four-corner anchoring across extreme deltas, negative
  screen coordinates, undersized displays, launcher spacing, and idempotent clamping passed.
- `Checks/PlaybackStateChecks.swift`: disconnected control guard, progress tick, pause,
  seek bounds, sample-track change, sleep/wake and preview shutdown passed.
- Compile geometry checks with WidgetGeometry.swift; playback checks with AppStore.swift.
- User accepted the static visual baseline; new event/animation behavior needs hands-on
  validation. Launch at Login is wired but was not enabled/tested on this unsigned temp build.
- Existing whitespace warning in Untitled.swift predates these edits and was left intact.

## Spotify authentication milestone implemented (phase 3)

- Compact scrollable Settings with Client ID save, Developer Dashboard link,
  exact redirect URI copy, Connect/Reconnect, Cancel Login, Disconnect and status.
  Setup opens automatically when no valid Client ID is configured.
- Browser PKCE with secure verifier/state, SHA-256 S256 challenge, fixed
  `http://127.0.0.1:8888/callback`, and the three planned playback scopes.
- Network.framework listener bound explicitly to loopback. Listener is ready
  before browser launch; validates request path, Host, state, duplicate parameters;
  limits headers to 8 KiB, concurrent connections to 8, connection lifetime to
  10 seconds, and login lifetime to five minutes. No codes/tokens logged.
- Keychain session storage, restore on launch, proactive refresh with a 60-second
  margin, coalescing, refresh-token retention, bounded retry and Retry-After.
- Session generation guards reject late work after cancellation, ID change,
  disconnect, sleep or shutdown. Disconnect disables restoration before Keychain
  deletion so a deletion error cannot silently reconnect on relaunch.
- Incoming/outgoing network capabilities enabled in both configurations. No ATS
  arbitrary-loads exception. Existing appearance/geometry and sample playback retained.
- Full unsigned Debug build passed. New authentication checks and real local
  loopback/isolated Keychain integration checks passed. See `SPOTIFY_SETUP.md`.
- Staged phase 3 sources: `/tmp/squidd-native-phase3`. Older phase 1/2 copies
  are historical and must not overwrite the newer authentication integration.

## Live Spotify milestone implemented (phase 4)

- Shared observable SpotifyPlayback controller drives both panels. AppStore routes
  preview locally and live actions to the controller; Preview Off restores live mode.
- One serialized worker polls the full playback-state endpoint at a configurable
  one-second interval. `GET /v1/me/player?additional_types=track,episode` intentionally
  replaces the planned currently-playing endpoint to include device restrictions
  in the same request. Hidden-card playback continues through the shared launcher.
- Exact previous/next/play/pause/seek APIs, command duplicate suppression, stale
  pre-command GET rejection and 400 ms reconciliation. Seek rolls back on failure.
- Device/item/action restrictions, track/episode/local/null/ad handling, one retry
  after 401, reconnect on persistent 401, 204 idle, 403 access diagnosis, 404 Open
  Spotify, Retry-After, quota halt and bounded transient backoff. No errors in titles.
- Monotonic 250 ms elapsed interpolation with duration clamp; no auto-skip at end.
- Shared 40-entry LRU of off-main decoded 300-pixel CGImage thumbnails. Bounded
  download size/time, stale artwork rejection and 30-second retry after image errors.
  Both artwork squares preserve their original frames and crossfade on updates.
- Synchronous auth session-change notification cancels and clears playback on
  disconnect/reconnect. Sleep, preview and app shutdown cancel worker/tick/art tasks.
- Settings shows live status and Open Spotify / Retry Playback. Launcher adds Open
  Spotify. Approved glass appearance hook and geometry remain unchanged.
- Full unsigned Debug build passed without new Swift warnings (only the existing
  AppIntents metadata-extraction note). Mock authentication/live playback, real PNG
  cache/decoding, preview state and geometry suites passed. No real account playback
  was exercised by the agent. Setup and acceptance instructions: `SPOTIFY_SETUP.md`.
- Current staging: `/tmp/squidd-native-phase4`. Do not restore older phase copies
  over the current authentication/playback implementation.

## Next

Real-account acceptance for phases 3/4 remains: connect/consent, actual metadata and
artwork, play/pause/previous/next/seek, hidden-card updates, no active device,
relaunch without login, token refresh and logout. Mock tests cannot prove account
eligibility or live device behavior. Signed App Sandbox runtime also remains pending.

Phase 5 hands-on accessibility/lifecycle: resize handles, transparent click-through,
global shortcuts while another app is focused, GIF freeze/resume, VoiceOver/keyboard
seeking, Spaces/fullscreen, display removal, relaunch placement and Launch at Login;
then profile idle/playing resources and finish distribution handoff in phase 6.

## User verification and visual polish

- User confirmed real-account Spotify playback: “it works fine.”
- Removed the white shadow/glow from emitted music-note particles at user request.
  Particle motion and the launcher rim remain as implemented. Debug build passed.
