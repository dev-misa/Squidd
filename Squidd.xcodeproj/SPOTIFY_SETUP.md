# Spotify setup and live playback — native phases 3–4

This build connects your account and displays live track/episode metadata, shared
artwork, progress and playback state. Previous, next, play/pause and seeking send
commands to your active Spotify device. Playback preview remains separate sample
data; set Preview to Off for live playback.

1. Open Squidd Settings from the menu bar or launcher’s right-click menu.
2. Open **Developer Dashboard** and select or create your Spotify developer app.
3. Register exactly `http://127.0.0.1:8888/callback` as a redirect URI. Use the
   **Copy** button in Settings. Do not substitute `localhost`.
4. Paste the app’s public **Client ID**, then click **Connect Spotify**. No client
   secret is needed. The ID is saved in preferences; no restart is required.
5. Finish Spotify login in your browser. Return to Settings and confirm
   **Connected to Spotify**. The browser tab can be closed.
6. Use **Open Spotify** and start a song on your preferred device. The card and
   launcher share the same live session, including while the card is hidden.

Development-mode apps require a Premium app owner and the authenticating account
on the app’s allowed-user list. See Spotify’s current
[quota-mode requirements](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).
Authentication success alone does not prove playback API access.

If port 8888 is occupied, quit the old Electron app (or the app holding
that port) and reconnect. Login expires after five minutes, can be cancelled in
Settings, and is cancelled when the Mac sleeps. Settings shows denial, connection,
Keychain and configuration errors without displaying tokens or authorization codes.

Access/refresh tokens and expiry are stored in the macOS Keychain. Refresh runs
60 seconds before expiry, coalesces simultaneous requests, retains an omitted
refresh token and retries transient failures with bounded backoff. HTTP 429 delays
are honored. Disconnect cancels work, disables session restore and deletes the
saved Keychain item. Changing the Client ID disconnects the old session. Local
logout does not revoke Spotify account access; that can be managed at
[Spotify’s apps page](https://www.spotify.com/account/apps/).

## Playback behavior

One serialized loop polls `GET /v1/me/player?additional_types=track,episode` every
second after each completed request. This endpoint supplies metadata plus device
restrictions without a second request. Controls honor restricted devices, tracks
and disallowed actions. The poll interval is an internal constructor setting.

Commands run in the same loop, ignore duplicate clicks while busy, reject responses
that predate a command and reconcile after 400 ms. Seeking previews locally during
drag, submits once on release, and rolls back on command failure. Progress uses a
250 ms monotonic tick and clamps at duration; the widget does not automatically skip
tracks. Artwork is decoded off the main actor to a 300-pixel thumbnail and shared
through a 40-entry LRU cache. Late results cannot replace newer artwork.

HTTP 204 clears now-playing state. A 401 triggers one refresh/retry, then reconnect.
403 pauses automatic polling and explains account/permission/Premium possibilities.
404 offers Open Spotify. 429 honors Retry-After; QUOTA_EXCEEDED halts automatic
requests. Settings provides an explicit Retry Playback action after resolving the
underlying issue. Other failures use bounded backoff and keep credentials. Sleep,
preview mode and logout cancel playback tasks; waking or leaving preview resumes
when connected. Metadata and artwork are cleared on logout.

## Checks performed

- PKCE SHA-256 against the RFC 7636 known vector and URL-safe random verifier.
- Form encoding and authorization URL parameters.
- Callback path, Host, state, duplicate parameter, denial and size validation.
- Mock login, relaunch restore, coalesced refresh, omitted refresh-token retention,
  transient failures, rate-limit delay, cancellation, Client ID change, logout
  despite Keychain deletion failure, and revoked authorization.
- Real loopback HTTP callback, wrong-state rejection, occupied port, cancellation
  and port reuse. No real Spotify account used in these tests.
- Real Keychain create/read/update/delete using a unique test-only service name.
- Mock live playback: track/episode/ad/local/null shapes, restriction decoding,
  command verbs/seek values, one-retry 401, 204/403/404/429/quota responses,
  serialized commands, stale polls, seek rollback, progress clamping, paused time,
  rate-limit waiting, sleep, preview isolation, quota halt and logout.
- Artwork: real PNG thumbnail decoding through a mocked download, LRU eviction,
  cached reuse, and stale image rejection after track changes.
- Existing preview playback and geometry regressions passed.
- Full unsigned Debug Xcode build. Incoming/outgoing network capabilities enabled
  for both Debug and Release; no global ATS exception added.

Browser login with your real developer Client ID, relaunch with real credentials,
actual expired-token refresh, and live device playback still need account testing. The runnable local
build is unsigned; signed App Sandbox behavior must also be checked before distribution.

## Hands-on playback acceptance

After connecting, start a song in Spotify and check title, artist, both artwork
squares, elapsed time, play/pause, previous/next and seeking. Hide the card and
confirm the launcher continues updating. Pause and resume to check the mascot.
Then test no active device, sleep/wake, relaunch, and disconnect. The automated
checks above use simulated Spotify responses and do not prove account eligibility.

## Build and tests

Run from `Squidd.xcodeproj` with Xcode installed at `/Applications/Xcode.app`:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ../Squidd.xcodeproj -scheme Squidd \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/squidd-native-build CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -parse-as-library -target arm64-apple-macos26.0 \
  -module-cache-path /tmp/squidd-swift-cache \
  ../Squidd/SpotifyAuth.swift ../Squidd/SpotifyLoopback.swift \
  ../Squidd/SpotifyTokenStore.swift Checks/SpotifyAuthChecks.swift \
  -o /tmp/squidd-auth-checks
/tmp/squidd-auth-checks
/tmp/squidd-auth-checks --integration
```

Run all authentication, live playback, preview and geometry checks with:

```sh
bash Checks/run-swift-checks.sh
```

The integration option temporarily binds port 8888 and writes/removes a dedicated
Keychain test item. It does not read or modify the app’s Spotify credentials.
Swift Observation macro compilation needs to run outside the agent sandbox.

References: [PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow),
[refresh](https://developer.spotify.com/documentation/web-api/tutorials/refreshing-tokens),
[redirect URI](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri).

Playback references: [state and restrictions](https://developer.spotify.com/documentation/web-api/reference/get-information-about-the-users-current-playback), [seek](https://developer.spotify.com/documentation/web-api/reference/seek-to-position-in-currently-playing-track).
