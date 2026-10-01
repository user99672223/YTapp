#!/usr/bin/env python3
"""keyrun — presses remote buttons at a steady, realistic pace over one pyatv connection.

`tv key down 10` starts atvremote (and a new connection) for every press, which takes about a
second each; scrolling tests need presses 0.3–0.6 s apart. This keeps one Companion connection
open and runs a small script of steps:

  down*12@0.4      press Down 12 times, 0.4 s apart (up, left, right, select, menu, home,
                   play_pause work the same; the @ delay defaults to 0.5 s)
  shot:NAME        screenshot through tvd, taken in the background so the presses keep their pace
                   (the picture lands 0.1-0.6 s later: a key listed right after it is usually
                   pressed BEFORE the capture, so the shot shows the result of that key)
  snap:NAME        screenshot that finishes before the next step (use it to see a state)
  mark:TEXT        marker line in tvd's logs (spaces as _)
  wait:1.5         pause

Example:  keyrun.py "mark:home_down down*20@0.4 shot:home-20 wait:1 up*20@0.4 shot:home-back"

Uses the pairing in ~/.pyatv.conf; TV_IP skips the bonjour scan.
"""
import asyncio
import os
import sys
import threading
import time
import urllib.parse
import urllib.request

import pyatv
from pyatv.storage.file_storage import FileStorage

API = f"http://127.0.0.1:{os.environ.get('TVD_PORT', '8777')}"
SHOTS = os.environ.get("TV_SHOTS", os.path.expanduser("~/tvtools/shots"))
KEYS = {"up", "down", "left", "right", "select", "menu", "home", "play_pause"}


def api(method, path, **query):
    url = f"{API}{path}?{urllib.parse.urlencode(query)}"
    req = urllib.request.Request(url, method=method)
    with urllib.request.urlopen(req, timeout=70) as r:
        return r.read().decode()


def shot_async(name, threads):
    out = os.path.join(SHOTS, f"{name}.png")
    started = time.monotonic()

    def run():
        try:
            api("GET", "/shot", out=out)
            print(f"  shot {name} ({time.monotonic() - started:.1f} s)", flush=True)
        except Exception as e:  # a failed screenshot shouldn't stop the run
            print(f"  shot {name} failed: {e}", flush=True)

    t = threading.Thread(target=run)
    t.start()
    threads.append(t)


async def main(script):
    loop = asyncio.get_running_loop()
    storage = FileStorage.default_storage(loop)
    await storage.load()
    hosts = [os.environ["TV_IP"]] if os.environ.get("TV_IP") else None
    found = await pyatv.scan(loop, hosts=hosts, storage=storage, timeout=5)
    found = [c for c in found if c.get_service(pyatv.const.Protocol.Companion)]
    if not found:
        sys.exit("no Apple TV with the Companion protocol found (set TV_IP?)")
    atv = await pyatv.connect(found[0], loop, storage=storage)
    threads = []
    try:
        rc = atv.remote_control
        for step in script.split():
            if step.startswith("shot:"):
                shot_async(step[5:], threads)
            elif step.startswith("snap:"):
                shot_async(step[5:], threads)
                await asyncio.to_thread(threads[-1].join)
            elif step.startswith("mark:"):
                api("POST", "/mark", text=step[5:].replace("_", " "))
                print(f"mark {step[5:]}", flush=True)
            elif step.startswith("wait:"):
                await asyncio.sleep(float(step[5:]))
            else:
                step, _, delay = step.partition("@")
                key, _, count = step.partition("*")
                if key not in KEYS:
                    sys.exit(f"unknown step {step}")
                n = int(count or 1)
                pause = float(delay or 0.5)
                for _ in range(n):
                    await getattr(rc, key)()
                    await asyncio.sleep(pause)
                print(f"{key} x{n} @{pause}s", flush=True)
    finally:
        pending = atv.close()
        if pending:
            await asyncio.wait(pending)
        for t in threads:
            t.join()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    asyncio.run(main(sys.argv[1]))
