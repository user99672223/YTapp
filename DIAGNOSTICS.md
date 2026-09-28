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

**Some videos wouldn't start ("Network problem").** For many videos (in our tests two of every
four 4K videos) YouTube's video servers refused the TV client's stream with "403 Forbidden",
even though the request for the video itself had worked; the app then blamed your internet
connection. Tube now tests the chosen stream with a one-byte request before playing. If it is
refused, Tube asks YouTube again without your account (as the visionOS, TV simply, iOS or
Android VR apps, which still get working streams) and plays that stream, while your history,
likes and "up next" keep going through your signed-in account. Only if that fails too does it
try the other signed-in clients.

**4K videos at 60 frames per second stuttered, and the sound drifted away from the picture.** The
Apple TV 4K (3rd generation) has no hardware decoder that apps can use for AV1 or VP9, the
formats YouTube uses for 4K, so Tube decodes them on the processor. Measured on your TV: 4K at
30 fps plays perfectly (about 270% of the CPU, no dropped frames), but 4K at 60 fps dropped up
to 40% of its frames and the sound ran up to 30 seconds ahead. The quality rule now knows this
limit: it still picks the best stream, but never one heavier than 4K at 30 fps, so 60 fps
videos play at 1440p60. The log says when a video was stepped down this way.

**"Try YouTube Premium" appeared in Up next.** A promotion shaped like a video card was listed as
the next video (and could be autoplayed). Cards that open something other than a video are now
left out.

**The stats box covered the side panels.** With "Show stats while playing" on, the numbers were
drawn over the Captions, Speed and Quality panels. The box now hides while a panel is open.

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

## The player

**A video that broke partway through counted as watched.** When a stream died (its links expire
after about six hours, YouTube can refuse them, connections drop), the player reported a normal
ending, so Tube deleted your resume point and moved on. Tube now keeps your place and fetches fresh
links up to twice before showing an error.

**No sound, or sound over a black screen.** If the audio or the picture failed to open, the video
just played without it. Tube now checks both and otherwise says which one failed.

**Every player error said "check the Apple TV's internet connection".** All player failures were
filed as network problems. The message now gives the real reason, and when YouTube refused the
stream it suggests Retry or another stream client.

**Switching videos mixed up the old one and the new one.** The previous video kept playing while the
next loaded, and its position became the new video's resume point. The old video now pauses,
anything still arriving from it is ignored, and Retry starts at the right place.

**Captions changed after a quality change or Retry.** Both reload the video, which then got the
Settings default instead of your choice. Your current choice is now kept.

**Controls froze while captions downloaded.** The player waited up to 30 seconds for the caption
file and ignored presses meanwhile. Captions now download in the background.

**The watch screen redrew itself on every frame.** Playback statistics rebuilt the screen every
frame, even when hidden, slowing AV1 videos. They now update once a second.

**YouTube was told you were watching while paused.** Watch-time reports only learned about pauses
from position updates, which stop during a pause. Pause and resume are now reported directly.

**The TV stayed at the video's refresh rate after leaving it.** Pressing Menu in the second before
Tube switched the TV's frame rate left the whole app at 24 or 50 Hz. That late switch is now
cancelled.

**Videos started playing after pressing the TV button.** A video still opening when you left Tube
began playing in the background, and autoplay could move on. It now stays paused.

**A quick second Play/Pause press was ignored.** The button acted before the player confirmed the
first press. The player now simply flips its own state.

**Speeds were shown rounded.** 1.25× read "1.2×" and 1.75× read "1.8×", though the right speed was
used. The labels are now exact.

**Comments could spin forever.** Moving to another video or Short while comments were loading meant
the new ones never loaded. Switching now cancels the old request.

**Age-restricted videos were blamed on a bot check.** YouTube's "Sign in to confirm your age"
matched Tube's bot-check test. It is now shown as a sign-in problem with YouTube's own reason.

**Removed videos showed a vague message after a long wait.** YouTube's reason for a deleted video was
hidden behind "This video is unavailable", so Tube tried every stream client. It now stops and shows the reason.

**Live streams tried to play and then failed.** The pieces of a live stream looked like normal
video files, so the player stopped after one. Tube now shows its "live streams aren't supported" message right away.

**A hand-picked stream client stuck around after going back to Automatic.** Tube remembered it as
the client that works. Changing the setting now clears that memory.

**The chosen quality was sometimes not the one that played.** After switching clients, Tube could
look up a stream in the wrong client's list. It now names the exact stream and reloads on a
mismatch.

**Proof-of-origin tokens were made with a wrong clock.** The clock the token code reads counted from
the Apple TV's last restart, so it ran days ahead. It now counts from Tube's start.

**Player problems were hard to find in the log.** Player errors were logged as routine messages,
some endings weren't logged, and the warning that YouTube changed its player in a way Tube can't
unlock never appeared. All now log correctly.

## Shorts

**Most Shorts never reached your watch history.** The previous Short kept looping while the next
loaded and used up the "playback started" signal meant for the new one. It now pauses while the next
loads, and its leftover updates are ignored.

**The Subscribe button in Shorts read "Sub-scribe".** The button was too narrow, so its label
broke over two lines. It now keeps the word on one line.

**Shorts played blurry.** A 1080p Short is 1080 by 1920 pixels, and Tube compared the 1920 with your
maximum quality, so a 1080p limit gave 480p. Vertical videos are now judged by their shorter side.

**A failed Short kept the screensaver off.** A Short that failed to load was never paused, so the
screensaver stayed off on the error screen, a burn-in risk on OLED sets. Errors now let it run.

**Memory use grew during long Shorts sessions.** Tube kept the full details of every Short it
showed. It now keeps five behind and two ahead.

## Home, Subscriptions, Library and feeds

**Scrolling further in Subscriptions, Channels or Playlists showed an error.** The library Tube uses
can only read the first page of these lists. Tube now reads later pages itself.

**The end of a list could send requests to YouTube nonstop.** When the next page failed to load, the
"Load more" footer reappeared and fired again for as long as it was on screen. Failures now show
Retry and are never retried on their own.

**Lists jumped back to the top on refresh.** Every refresh rebuilt the whole list, dropping loaded
pages and focus. A background refresh now waits behind a "Show the latest" button, and new pages
only add what is new.

**Failed refreshes were invisible.** An empty list whose refresh failed just said, for example,
"Watch Later is empty". The error now shows with Retry.

**Retry looked like it did nothing, or threw focus to the top.** Error screens didn't change while
Retry worked, and at the end of a list the button became a spinner that can't hold focus. Retry now
shows "Retrying…" and keeps focus.

**Save to Watch Later gave no feedback.** Success and failure were both silent, and Library kept the
old list for 15 minutes. Tube now confirms or shows an error, and reloads the list.

**Removing from Watch Later was slow and could fail oddly.** Tube read the whole Watch Later list to
find the video. It now sends one direct remove request, as YouTube's own apps do.

**Playlists often had no Play button.** The header didn't notice when the videos arrived, and a
saved copy lacked the title, channel and count. Both are fixed.

**Watch Later, Liked and playlists showed no views or dates.** YouTube puts both in one line there,
which Tube never read. It now does.

**Mix cards opened a playlist that always failed.** YouTube has no playlist page for Mixes, so a Mix
now plays its first video.

**Premieres and scheduled streams looked playable.** Tube missed YouTube's newer "Upcoming" label,
so tapping one led to "Not live yet". It now reads it.

**Finished live streams kept a red LIVE label.** Feeds keep the picture taken while on air. Tube now
uses the normal thumbnail once a stream has ended.

**Every grid of Shorts was titled "Shorts".** Tube never read the real title. It does now.

## Search

**Typing with the Siri Remote never started a search.** Search only ran on Return, which the
remote's keyboard doesn't have. Tube now searches once you stop typing for a second.

**Search filters changed the label but not the results.** The step that re-runs the search was
thrown away by the very change that should trigger it. Filters now work and keep focus.

**Searching the same thing again showed "Loading…" forever.** The new list was never loaded. The
same search now keeps the results already on screen.

**Down from some search filters didn't reach the results.** Depending on which filter was
highlighted, pressing down went nowhere. The results are now their own area, so down always
lands in them.

## Channels

**Channel videos showed the view count as the channel name.** Cards on a channel's Videos tab read
"1.2M views • 1.2M views • 3 days ago" because Tube took the first line as the channel. Tube now
finds the channel by its link, and views and dates by their wording.

**Channels with "video" in their handle lost their video count.** For @videogamedunkey the header
showed the handle twice. The handle is now skipped.

**Reopening a channel within an hour left Videos spinning forever.** When fresh channel details
arrived, Tube swapped the tab it was loading for an empty one. Tabs are now kept and always load.

**A channel could show another channel's videos.** A channel restored from an earlier launch kept an
internal reference that could now point to a different channel. Tube now checks it first.

**Moving across channel tabs dropped focus onto Subscribe.** Every tab change rebuilt the whole
screen, tab picker included. Only the list below the picker changes now.

**Subscribe failed silently and lost focus.** Failures were never shown, and the button disabled
itself while busy, which pushes focus away on tvOS. Failures now open an alert, and the button stays
focused.

## Sign-in, settings and storage

**Settings reset without warning.** On a real Apple TV, settings ended up in a folder tvOS empties
when space runs low. They now live in storage tvOS keeps.

**Signing in with another account kept showing the old account.** Home, Subscriptions and Library
showed the old account's lists for up to 15 minutes. New cookies now clear everything saved.

**Switching accounts could bring the old one back or break the new sign-in.** A connection or
request started before the switch could finish afterwards, restoring the old account or mixing its
cookies into the new ones. Both now check they still belong to the current sign-in.

**Sign-ins broke after running for days.** After days, Tube lost track of which cookies the live
session was using, so requests went out with stale ones. It now always keeps track.

**Fresh cookies were lost if you left Tube quickly.** Updated cookies were saved five seconds late,
so if tvOS closed Tube in between, they were lost. They are now saved as soon as Tube leaves the
screen.

**A sign-in could vanish on the next launch with no reason given.** Errors from the TV's secure
storage (the Keychain) were ignored. Failures are now logged, and a banner warns that the sign-in
won't survive a restart.

**Cancel on the setup screen led to "still connecting" everywhere.** Cancelling "Re-enter cookies"
opened the main screens with no connection. Cancel now reconnects, showing progress or the real
error.

**Settings lists didn't show what was selected.** Opening Maximum quality, Stream client, PO tokens
or Caption language showed the options without any mark on the current one, so you couldn't tell
what was set. These lists now put a checkmark on the current choice and go back to Settings when
you pick one.

**The focused "Sign out" row was unreadable.** Its red text turned pale pink on the white
highlight. It (and "Clear cache") now turns dark red when highlighted.

**The top bar cut off a tab.** Six tabs didn't fit, so "Settings" (or "Home") was faded out at the
edge. "Subscriptions" is now "Subs", and Search and Settings are shown as their icons, like
Apple's own TV apps, so all six fit.

## Setup and Debug screens

**"Download newer bundle" never worked on the TV, and its result never showed.** It saved into a
folder only the simulator can write to, and the result message vanished when Settings was rebuilt.
Downloads now go where tvOS allows, and the result stays on screen.

**The setup page could stop working for good.** tvOS closes a sleeping app's network connection,
which broke the small web server that receives your cookies, with no Retry. It now restarts when
Tube comes back, and failures show Retry.

**The Debug screen couldn't be scrolled.** tvOS only scrolls to things that can be highlighted, and
only the two buttons could. Every row can now be highlighted.

**The setup screen cut its instructions short.** The four steps ended in "…" and the address broke
after "http://". The text now wraps fully and the address stays on one line.

**Menu on the Debug screen left the app.** Because nothing on that screen could be highlighted,
tvOS treated Menu as "leave Tube". Now that every row can be highlighted, Menu goes back to
Settings.
