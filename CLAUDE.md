# Tube — tvOS YouTube client (agent notes)

Personal, sideloaded YouTube client for Apple TV 4K (tvOS 17+). Everything runs on the device:
YouTube.js inside JavaScriptCore for InnerTube access, libmpv (MPVKit) for playback.

## Layout
- `project.yml` — XcodeGen spec. **Never hand-edit a `.pbxproj`**; the project is generated in CI.
- `App/Sources/App` — `TubeApp` (entry + root/tab views), `AppModel` (runtime + session lifecycle,
  auth-error recovery via `api {}`), `Router` (tabs, stacks, full-screen players), `Persistence`
  (settings in UserDefaults; SwiftData in Caches for resume positions and the feed cache — tvOS
  apps can only write to Caches/tmp, and Caches may be purged).
- `App/Sources/YouTubeBridge` — `JSRuntime` (JavaScriptCore host + `__native` functions, implements
  Core's `BridgeTransport`), `NativeHTTP` + `CookieStore` (URLSession fetch, cookie rotation),
  `KeychainStore`, `BundleManager` (downloaded vs built-in bundle). The typed API is Core's
  `YouTubeService`.
- `App/Sources/Player` — `MPVPlayer` (libmpv), `PlayerViews` (Metal view, frame-rate matching,
  CPU/memory stats), `PlaybackReporter` (history + watch-time pings), `PlaybackDiagnostics`.
- `App/Sources/Features/*` — one folder per screen (Setup, Home, Subscriptions, Shorts, Search,
  Watch, Channel, Library, Settings) + `Features/Shared` UI components.
- `App/Resources/js/youtubei.bundle.js` — built by `js/` and **committed**. CI fails if stale.
- `Packages/Core` — pure Swift (no UIKit/JSC): models (DTOs decoded from the bridge), quality rule,
  bridge protocol, cookie parsing, setup HTTP parsing, watch-time tracking, refresh policy.
  Must build and test on Linux.
- `js/` — esbuild project: `src/polyfills/*` (what JavaScriptCore lacks), `src/bridge/*`
  (the `TubeBridge` API + normalizers that turn YouTube.js nodes into plain JSON DTOs),
  `test/` (Node smoke test that loads the bundle in a bare `vm` context with a fake native layer).

## Testing on the Apple TV
`tools/tv/` (see its README): rootless Wi-Fi developer tunnel (syslog, screenshots, launch, crash
reports), pyatv remote buttons, and installs through atvloadly's MCP API. CI only builds by itself
on `main` and tags; run `gh workflow run ci.yml --ref <branch>` for a branch.

## Commands
- Core tests: `cd Packages/Core && swift test`
- JS: `cd js && npm ci && npm run bundle && npm test` (then commit `App/Resources/js/youtubei.bundle.js`)
- App: only builds on macOS: `xcodegen generate` then the `xcodebuild` line in `.github/workflows/ci.yml`.
- Release: push a `v*` tag, or run the CI workflow manually with input `release_tag` (e.g. `v1.0.1`);
  the build job creates the tag + GitHub Release and attaches `App-unsigned.ipa`.

## Contracts
- JS → Swift DTO shapes live in `js/src/bridge/normalize.js` and `Packages/Core/Sources/Core/Models`.
  Change both together; `Packages/Core/Tests/CoreTests/Fixtures/*.json` are produced from the JS
  normalizers and decoded in Swift tests.
- Native functions exposed to JS are on `globalThis.__native` (see `js/src/polyfills/native.js` and
  `App/Sources/YouTubeBridge/JSRuntime.swift`). The Node smoke test mirrors them.
- Streams: only `streaming_data.adaptive_formats`, every URL through `format.decipher(player)`.
  Never HLS/DASH manifests, never ad placements, never SABR.
- Stream clients (Sept 2026, see DIAGNOSTICS.md): signed in, `AUTO` tries TV (sent as the 5.x TV
  app, `platform.js`), TV_TIZEN (same client as a Samsung TV, for "The page needs to be
  reloaded"), WEB_EMBEDDED, MWEB (PO token). TV_SIMPLY/ANDROID_VR/IOS/VISIONOS answer signed-in
  requests with 400; they are only used through the cookieless `anonSession()` for stream URLs
  when googlevideo refuses the signed-in client's stream (one-byte probe in `resolveFormats`).
  History/watch-time always use the signed-in answer.
- Quality: the Apple TV 4K (A15) decodes AV1/VP9 in software only; `AppSettings.quality` carries a
  `DecodeBudget` (software formats up to 2160p30 pixels/s, so 60 fps plays at 1440p60).
- Logging: every `LogBuffer` line also goes to os_log (subsystem `com.local.tube`); failures must
  be logged, handled fallbacks at info level. Playback logs a stats line every 30 s.

## Rules
- Keep `main` buildable; CI (`check` on Linux, `build` on macOS) must stay green.
- No iCloud/CloudKit/app groups/fixed-team entitlements; bundle id `com.local.tube` may be rewritten.
- Feed refresh on timers only (Home/Subs 15 min, video info 5 min, channel 1 h).
- One playback session at a time; one fixed client identity; no bulk actions.
- Every failure is shown on screen with a plain message and a Retry button.
