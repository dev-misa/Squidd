#!/bin/bash
set -euo pipefail
# Optional source directory lets staged changes be checked before installation.
checks_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="${1:-$checks_dir/../../Squidd}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
compiler=(xcrun swiftc -parse-as-library -target arm64-apple-macos26.0 -swift-version 5
  -default-isolation MainActor -module-cache-path /tmp/squidd-swift-cache)
auth_sources=("$source_dir/SpotifyAuth.swift" "$source_dir/SpotifyLoopback.swift" "$source_dir/SpotifyTokenStore.swift")
playback_sources=("$source_dir/SpotifyPlaybackAPI.swift" "$source_dir/SpotifyPlayback.swift" "$source_dir/SpotifyArtworkCache.swift")
"${compiler[@]}" "${auth_sources[@]}" "$checks_dir/SpotifyAuthChecks.swift" -o /tmp/squidd-auth-checks
/tmp/squidd-auth-checks
"${compiler[@]}" "${auth_sources[@]}" "${playback_sources[@]}" "$checks_dir/SpotifyPlaybackChecks.swift" -o /tmp/squidd-live-playback-checks
/tmp/squidd-live-playback-checks
"${compiler[@]}" "${auth_sources[@]}" "${playback_sources[@]}" "$source_dir/AppStore.swift" "$checks_dir/PlaybackStateChecks.swift" -o /tmp/squidd-playback-checks
/tmp/squidd-playback-checks
"${compiler[@]}" "$source_dir/WidgetGeometry.swift" "$checks_dir/GeometryChecks.swift" -o /tmp/squidd-geometry-checks
/tmp/squidd-geometry-checks
