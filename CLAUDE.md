# Tube — tvOS YouTube client (agent notes)

Personal, sideloaded YouTube client for Apple TV 4K (tvOS 17+). Everything runs on the device:
YouTube.js inside JavaScriptCore for InnerTube access, libmpv (MPVKit) for playback.

## Layout
- `project.yml` — XcodeGen spec. **Never hand-edit a `.pbxproj`**; the project is generated in CI.
- `App/Sources/App` — app entry, root/tab navigation, shared app state, SwiftData persistence.
- `App/Sources/YouTubeBridge` — JavaScriptCore runtime, native polyfill backing (fetch via URLSession,
  timers, crypto, file cache), `YouTubeClient` (typed async API over the JS bridge), Keychain.
- `App/Sources/Player` — libmpv wrapper, Metal layer view, display criteria (frame-rate match),
  watch-history sync, CPU monitor.
- `App/Sources/Features/*` — one folder per screen (Setup, Home, Subscriptions, Shorts, Search,
  Watch, Channel, Library, Settings) + `Features/Shared` UI components.
- `App/Resources/js/youtubei.bundle.js` — built by `js/` and **committed**. CI fails if stale.
- `Packages/Core` — pure Swift (no UIKit/JSC): models (DTOs decoded from the bridge), quality rule,
  bridge protocol, cookie parsing, setup HTTP parsing, watch-time tracking, refresh policy.
  Must build and test on Linux.
- `js/` — esbuild project: `src/polyfills/*` (what JavaScriptCore lacks), `src/bridge/*`
  (the `TubeBridge` API + normalizers that turn YouTube.js nodes into plain JSON DTOs),
  `test/` (Node smoke test that loads the bundle in a bare `vm` context with a fake native layer).

## Commands
- Core tests: `cd Packages/Core && swift test`
- JS: `cd js && npm ci && npm run bundle && npm test` (then commit `App/Resources/js/youtubei.bundle.js`)
- App: only builds on macOS: `xcodegen generate` then the `xcodebuild` line in `.github/workflows/ci.yml`.

## Contracts
- JS → Swift DTO shapes live in `js/src/bridge/normalize.js` and `Packages/Core/Sources/Core/Models`.
  Change both together; `Packages/Core/Tests/CoreTests/Fixtures/*.json` are produced from the JS
  normalizers and decoded in Swift tests.
- Native functions exposed to JS are on `globalThis.__native` (see `js/src/polyfills/native.js` and
  `App/Sources/YouTubeBridge/JSRuntime.swift`). The Node smoke test mirrors them.
- Streams: only `streaming_data.adaptive_formats`, every URL through `format.decipher(player)`.
  Never HLS/DASH manifests, never ad placements.

## Rules
- Keep `main` buildable; CI (`check` on Linux, `build` on macOS) must stay green.
- No iCloud/CloudKit/app groups/fixed-team entitlements; bundle id `com.local.tube` may be rewritten.
- Feed refresh on timers only (Home/Subs 15 min, video info 5 min, channel 1 h).
- One playback session at a time; one fixed client identity; no bulk actions.
- Every failure is shown on screen with a plain message and a Retry button.
