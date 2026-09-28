# Diagnostics — September 2026

What was wrong with Tube, why, and what changed. One paragraph per problem, in plain language.
Found by running the app on the Apple TV 4K (3rd gen, tvOS 27.0) while reading its log and the
tvOS system log, by a code audit, and by testing single requests from a laptop.

How the checks were done: the laptop holds a developer connection to the TV over Wi‑Fi (no USB,
no root) that streams the TV's system log, takes screenshots, starts the app and collects crash
reports; `pyatv` presses the remote's buttons; new builds come from GitHub Actions and are
installed with atvloadly. Tools are in `tools/tv/` (see the README there).

## Playback

**Videos wouldn't play ("choose another stream client").** Tube asks YouTube for a video's
streams while pretending to be one of YouTube's own apps (a "client"). By September 2026 YouTube
had changed what each client gets. The default "TV" client (TV app version 7.x) now only receives
SABR streams when you are signed in — a newer streaming format this app deliberately does not use.
The alternatives in Settings were worse: TV simply, Android VR and iOS reject any request that
carries account cookies (HTTP 400), TV embedded is shut down, and Web only offers SABR. The fix
follows what yt-dlp does: Tube now introduces itself as an older version (5.x) of YouTube's TV
app, which still gets normal direct streams with your sign-in, and sends the TV app's user agent
instead of a desktop browser's. If YouTube answers "The page needs to be reloaded" (an experiment
some sessions are in) it retries as a Samsung TV, which works; after that come Web embedded and
Mobile web. Tube remembers which one worked. The Settings list now only offers clients that work
signed in, and every install was moved to "Automatic" once.

**The error screen was misleading.** The failing request above was shown as "Unexpected response"
because the error sorter saw the word "json" in the web address and called it a parsing problem.
Errors are now sorted without looking inside web addresses, and a refused video request is
reported as a stream problem.

**Some web-client settings sent a token everywhere.** When a web client made a "proof of origin"
token, it was stored for the whole session, so YouTube.js attached it to every later request and
stream address, including the TV client's. Tokens are now made per video and only sent with the
video and client they belong to; Web embedded no longer asks for one at all.

## Crashes

**Tube crashed when a video closed (and when one started, and on the Debug screen).** tvOS 27
removed an old Apple function (`UIWindow.avDisplayManager`) that Tube used to switch the TV to a
video's frame rate. Calling a function that no longer exists stops the app immediately. Tube now
checks whether the function exists before using it (it still exists once the video system is
loaded, so frame-rate matching keeps working), and turns frame-rate matching off if it does not.

## Invisible errors

**Nothing reached the TV's system log.** The app only printed its messages in debug builds, so
installed builds wrote nothing anyone could read, and failures were invisible. Every message the
app keeps for its Debug screen now also goes to the system log (subsystem `com.local.tube`),
including every failed YouTube call with its type, status code and details, every stream client
that was tried, and YouTube.js' own warnings (the harmless parser ones at a lower level).
