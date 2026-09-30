# Driving the Apple TV from a Linux laptop

Everything here runs on the laptop, rootless, over Wi‑Fi. Used for the fix → build → install →
verify loop in [DIAGNOSTICS.md](../../DIAGNOSTICS.md).

| File | What it does |
| --- | --- |
| `tvtunnel.py` | Opens pymobiledevice3's userspace (no root) developer tunnel to the TV over Wi‑Fi. pymobiledevice3's own `--userspace` only finds devices over USB; this builds the tunnel from the TV's `_remotepairing._tcp` bonjour service instead. |
| `tvd.py` | Daemon holding that tunnel. Streams the TV's system log into `~/tvtools/logs/` (`tube.log` = Tube's own messages and its errors, `app.log` = everything from the app's process, `sys.log` = crashes, jetsam, sandbox, GPU and network trouble, `all.log` = everything) and serves a small API on `127.0.0.1:8777` for screenshots, app launch/kill and crash reports. Reconnects on its own. |
| `tvd-ctl.sh` | `start` / `stop` / `restart` the daemon (pid file; don't use `pkill -f`, it matches your own shell). |
| `tv` | Front end: `tv status`, `tv shot NAME` (PNG in `~/tvtools/shots`), `tv launch`, `tv kill`, `tv pid`, `tv crash DIR [REGEX]`, `tv mark TEXT` (marker line in the logs), `tv key up\|down\|left\|right\|select\|menu\|home\|play_pause [N]` (remote buttons via pyatv). Type into a focused text field with `atvremote text_set="…"`. |
| `keyrun.py "STEPS"` | Presses buttons at a steady pace over one pyatv connection (`tv key` reconnects for every press, about a second each): `down*20@0.4`, `shot:NAME` (taken in the background), `mark:TEXT`, `wait:1.5`. Run it with pyatv's Python (`~/.local/share/pipx/venvs/pyatv/bin/python`). |
| `scrollstats.py LOG OFFSET` | Counts, per mark, what the app did in a log from byte `OFFSET` on (take it with `stat -c %s` before a test): focus moves, image/API requests and URLCache hits, the UIKit preference lookups, hangs, memory warnings, SwiftUI warnings, Tube's errors and its `images:` stats lines. Sorts lines by their own time, since the stream arrives seconds late. |
| `install.sh RUN_ID` | Downloads the IPA from a GitHub Actions run and installs it through atvloadly's MCP API as an update of the existing Tube; closes Tube first and verifies the stored IPA. |
| `mcp.sh METHOD PARAMS` | Minimal client for atvloadly's MCP endpoint (`tools/list`, `tools/call`). |

## One-time setup

```bash
pipx install pymobiledevice3
pipx install pyatv
```

- **pyatv** needs Companion pairing once (`atvremote --id <id> --protocol companion pair`, PIN
  shown on the TV). Credentials land in `~/.pyatv.conf`.
- **pymobiledevice3** needs a RemotePairing record in `~/.pymobiledevice3/remote_<UDID>.plist`.
  Either pair (`pymobiledevice3 remote pair`, TV on *Settings → Remotes and Devices → Remote App
  and Devices*), or reuse atvloadly's record from
  `/etc/atvloadly/PlumeImpactor/pairing_files/<UDID>.plist`: copy `private_key`, `public_key`,
  `alt_irk` (also as `peer_alt_irk`), set `host_identifier` to its `identifier` and
  `remote_unlock_host_key` to `""`.
- The TV needs Developer Mode on and the developer disk image mounted (atvloadly mounts it).

Environment overrides: `TV_IP` (direct connection when bonjour is quiet), `TV_UDID`, `TV_BUNDLE`,
`ATVLOADLY_MCP`, `ATVLOADLY_DEVICE_ID`, `ATVLOADLY_ACCOUNT_ID`.

## The loop

```bash
tools/tv/tvd-ctl.sh start
gh workflow run ci.yml --ref <branch>          # CI only runs by itself on main and tags
tools/tv/install.sh <run id>
tools/tv/tv launch; tools/tv/tv mark "test X"
tail -f ~/tvtools/logs/tube.log
```

## Measuring a scroll

```bash
size=$(stat -c %s ~/tvtools/logs/app.log)
~/.local/share/pipx/venvs/pyatv/bin/python tools/tv/keyrun.py \
  "mark:down down*20@0.45 shot:after-down wait:2 mark:up up*20@0.45 shot:after-up wait:2 mark:end"
sleep 5    # the log stream lags a few seconds behind the TV
tools/tv/scrollstats.py ~/tvtools/logs/app.log "$size"
```

Never grep a whole log: they grow by gigabytes. Read only the bytes after the offset.
