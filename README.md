# Tube for Apple TV

Tube is a personal YouTube app for Apple TV 4K. It plays YouTube with its own video player
(AV1, VP9 and Opus in software, always the highest quality, no ads), and it is signed in to
**your** YouTube account, so Home, Subscriptions, history, likes, Watch Later, playlists,
comments, search, channels and Shorts all work like the real app. What you watch in Tube is
added to your YouTube history, so your recommendations keep learning.

Everything runs on the Apple TV. There is no server. Your YouTube sign-in (cookies) is stored
only in the Apple TV's Keychain and is only sent to YouTube.

---

## 1. Download the app

1. Open the latest release: **https://github.com/user99672223/YTapp/releases/latest**
2. Under **Assets**, download **`App-unsigned.ipa`** to your computer.

## 2. Install it on the Apple TV with Sideloadly

You need a Mac or Windows computer, your Apple ID, and the Apple TV on the same home network.

1. Install **Sideloadly** from https://sideloadly.io and open it.
2. On the Apple TV open **Settings → Remotes and Devices → Remote App and Devices**
   and leave that screen open.
3. In Sideloadly your Apple TV appears in the device list (choose it). If Sideloadly asks for
   a pairing code, type the code the TV shows.
4. Drag **`App-unsigned.ipa`** into Sideloadly, enter your Apple ID, and press **Start**.
   (Sideloadly signs the app with your Apple ID and may change its bundle ID — that's fine.)
5. When it says **Done**, the **Tube** icon is on the Apple TV home screen.

> With a free Apple ID the app works for 7 days; then open Sideloadly and install it again
> (your sign-in and settings are kept). With a paid Apple developer account it lasts a year.

**Optional — match frame rate:** Tube can switch the TV to a video's frame rate so films play
without judder. Every switch blanks the picture for a moment and makes some TVs flicker for a
while, so this is **off** by default. To use it, turn on **Match Frame Rate** on the Apple TV
(**Settings → Video and Audio → Match Content**), then choose in Tube's **Settings → Match frame
rate**:
- **24 fps videos only** — films (23.976/24 fps) switch the TV to 24 Hz; everything else plays at
  the TV's usual rate.
- **All videos** — 24 fps → 24 Hz, 25/50 fps → 50 Hz, 30/60 fps → 60 Hz.

Tube switches at most once per video (never again for a quality change or Retry), keeps the mode
while the next videos have the same frame rate, and puts the TV back to its usual rate when you
leave the player.

## 3. Sign in: copy your YouTube cookies to the TV

Tube signs in with your browser's YouTube cookies. Take them from a **private window** so your
normal browser keeps working independently.

1. On your computer open a **private / incognito window** (Chrome: `Ctrl/⌘ + Shift + N`,
   Firefox: `Ctrl/⌘ + Shift + P`).
2. Go to **youtube.com** and **sign in** with the account you want on the TV.
3. Export the cookies:
   - **Chrome / Edge:** install the extension **“Get cookies.txt LOCALLY”**. In the extension's
     settings turn on **Allow in Incognito**. With youtube.com open in the private window, click
     the extension and choose **Copy** (Netscape format).
   - **Firefox:** install **“cookies.txt”**, allow it in private windows, open it on youtube.com
     and copy the cookies for the current site.
4. Start **Tube** on the Apple TV. It shows a **QR code** and an address like
   `http://192.168.1.20:8765`. (If the TV asks whether Tube may find devices on your local
   network, choose **Allow**.)
5. Open that address on your computer (or scan the QR code with your phone), **paste** the
   cookies into the box and press **Send to TV**.
6. The page and the TV both say **“Signed in as …”**. Tube opens your Home feed.
7. Now **close the private window**. **Don't press “Sign out”** on YouTube there — signing out
   would cancel the cookies you just gave the TV.

If you ever need to sign in again: **Settings → Re-enter cookies** in Tube, then repeat step 3.

## 4. Using Tube with the Siri Remote

| Where | What to do |
| --- | --- |
| Anywhere | **Menu / Back** goes back |
| Video playing | **Play/Pause** button pauses; **left / right** on the touch surface jumps 10 s; **click** shows the controls |
| Controls | Move up to the progress bar and press **left / right** to scrub (hold on for bigger steps), **click** to jump; buttons for Chapters, Captions, Speed, Quality, Info (like, dislike, subscribe, Watch Later, description) and Comments; the **Up next** row is below |
| End of a video | The next video starts after a short countdown (turn off in Settings → Autoplay) |
| Shorts | Open the **Shorts** tab and press **Play Shorts** (or pick one). **Swipe down / up** for the next / previous Short. Like, dislike, comments and subscribe are under the video |
| Long press on a video | Save to Watch Later, go to the channel |

## 5. Settings

- **Maximum quality** — 4K by default. Order is always AV1 → VP9 → H.264 at the highest
  resolution, with Opus audio. Tube never switches quality while playing; it buffers instead.
- **Match frame rate** — **Off** (default), **24 fps videos only** or **All videos** (see
  section 2). Needs *Match Frame Rate* turned on in the Apple TV settings; the Debug screen
  shows whether it is, and the TV's usual rate.
- **Stream client** — how Tube asks YouTube for the video streams. **TV** is the default. If
  videos stop playing, try another one here.
- **YouTube bundle** — YouTube changes often. **Download newer bundle** fetches the latest
  version of the part of Tube that talks to YouTube, without reinstalling the app.
- **Clear cache**, **Re-enter cookies**, **Sign out**, and the **Debug screen** (CPU use, the
  exact streams chosen, buffer state and recent log messages). **Show stats while playing**
  puts the same numbers on top of the video.

## 6. If something goes wrong

Every problem shows a message on screen with a **Retry** button.

- **“YouTube didn't accept your sign-in”** — do *Settings → Re-enter cookies* with fresh
  cookies from a new private window.
- **A video won't start / “couldn't unlock the stream”** — press Retry; if it keeps failing,
  try *Settings → Download newer bundle*, then another *Stream client*.
- **4K AV1 stutters** — open the Debug screen while it plays (or turn on *Show stats while
  playing*); if the CPU is maxed out, set *Maximum quality* to 1440p or 1080p.
- **Live streams** are not supported (YouTube only offers them in a streaming format this app
  deliberately doesn't use). Finished streams play normally.

---

Developer notes (building, tests, layout) are in [CLAUDE.md](CLAUDE.md).
