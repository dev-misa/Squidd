# Apple Music setup and live playback

Apple Music needs no account, no developer app and no Client ID. Open Settings, allow
Squidd to control the Music app once, and the card and launcher follow whatever Music
is playing — including local library files, which Spotify cannot show at all.

1. Open Music and start a song.
2. Open Squidd Settings from the menu bar or the launcher's right-click menu.
3. In **Now Playing Source**, leave **Automatic** selected, or pin **Apple Music**.
4. Click **Allow Access** and approve the macOS Automation prompt.
5. The card shows the track, artwork and progress, and the transport buttons work.

If the prompt was dismissed or refused, the button becomes **Open Settings** and opens
System Settings › Privacy & Security › Automation, where Squidd's entry for Music can be
switched back on. macOS only ever asks once; after a refusal nothing but that panel can
undo it.

## Why not the Apple Music API

The obvious parallel to the Spotify integration does not exist. Apple's Web API at
`api.music.apple.com` is a catalog and library service: it has no currently-playing
endpoint and no transport endpoints, and it requires a paid Developer Program
membership plus an ES256-signed developer token. MusicKit does not help either — on
macOS, `SystemMusicPlayer`, the class that reads and controls the Music app, is declared
`@available(macOS, unavailable)`. Its sibling `ApplicationMusicPlayer` plays a queue
inside the host app, which would make Squidd a second music player rather than a widget
showing the first one.

What is left, and what every native Mac now-playing widget uses, is Apple events to the
Music app, driven from the scripting dictionary at
`/System/Applications/Music.app/Contents/Resources/com.apple.Music.sdef`. Squidd declares
the handful of properties it needs (`player state`, `player position`, `current track` and
its `artwork`) as small `@objc` protocols in `AppleMusicBridge.swift`, rather than
generating a four-thousand-line header with `sdp`.

The private `MediaRemote` framework would report now-playing for any app, not just Music.
It is entitlement-gated as of macOS 15.4 and disqualifies an app from the App Store, so
it is not used.

## Permissions

Talking to another app needs two things beyond the code:

- `com.apple.security.automation.apple-events` in `Squidd/Squidd.entitlements`, required
  under both the App Sandbox and the hardened runtime, narrowed to `com.apple.Music` by a
  `com.apple.security.temporary-exception.apple-events` entry.
- `NSAppleEventsUsageDescription`, set through `INFOPLIST_KEY_NSAppleEventsUsageDescription`,
  which is the sentence shown in the Automation prompt.

Permission is read with `AEDeterminePermissionToAutomateTarget` and `askUserIfNeeded: false`
everywhere except the **Allow Access** button, so the widget never interrupts on its own.
The three answers are told apart: not yet asked, refused, and Music not running.

## Playback behavior

The Music app broadcasts `com.apple.Music.playerInfo` on every track change and every
play or pause, so the widget is event-driven rather than polled. That notification needs
no permission at all, which is the graceful degradation path: with Automation refused the
card still shows the title and artist Music broadcasts, while the transport buttons and
seek bar stay disabled because nothing can be sent.

Apple events fill in what the notification omits. `player position` is re-read every five
seconds while playing and every fifteen while paused — not to notice a track change, which
the notification already reported, but to catch scrubbing done inside Music, which is
silent. Between reads the progress bar advances on the same 250 ms monotonic tick the
Spotify backend uses. There is no rate limit, no quota and no network, so these intervals
are chosen for freshness rather than for a budget.

ScriptingBridge calls are synchronous and block until the target answers, so every one of
them runs on a private serial queue and is awaited. None ever runs on the main actor,
where a busy Music app would freeze the widget; `SBApplication.timeout` caps a reply at
two seconds. Nothing is sent unless Music is already running, checked through
`NSRunningApplication` rather than an Apple event, so polling never launches Music or
trips a prompt by itself.

`player state` is decoded from the `ePlS` four-character codes, and an unrecognized value
becomes `.unknown` rather than silently reading as stopped. Fast-forwarding and rewinding
both count as playing. Artwork comes from the track's `raw data`, decoded off the main
actor to a 300-pixel thumbnail exactly as Spotify covers are, cached by track so it is
fetched once per track rather than once per refresh. Seeking previews locally during the
drag, clamps to the track duration, submits once on release and rolls back if the command
fails.

## Choosing between the two services

**Now Playing Source** in Settings offers Automatic, Spotify and Apple Music, saved under
the `musicSource` preference.

Automatic follows whichever service is actually playing. When both are playing, the one
that started most recently wins. When neither is, the current service keeps the card as
long as it still has a track loaded, so pausing Spotify does not hand the widget to an
idle Music app and back again. A service with nothing set up — no Spotify session, or
Music not running — is never chosen.

Both backends implement `MusicSource`, so the card, launcher, global shortcuts and ink
overrides work the same either way, and the launcher's right-click menu offers Open Music
or Open Spotify depending on which is showing. Sleep suspends both; waking resumes both.
