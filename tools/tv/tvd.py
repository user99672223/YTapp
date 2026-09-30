#!/usr/bin/env python3
"""tvd — holds one rootless Wi-Fi developer tunnel to the Apple TV and serves a tiny local API.

Logs (continuously, reconnecting if the tunnel drops), under $TVD_LOGDIR (default ~/tvtools/logs):
  all.log   every syslog line from the TV
  app.log   lines from the Tube app process (executable "App") and anything naming com.local.tube
  sys.log   tvOS-level trouble: crashes, jetsam/memory pressure, sandbox denials, GPU/Metal,
            networking errors, watchdog/termination reasons

HTTP on 127.0.0.1:8777 (all return JSON unless noted):
  GET  /status
  GET  /shot?out=/path/file.png          DVT screenshot
  POST /launch?bundle=ID                 (kills an existing instance first)
  POST /kill?bundle=ID
  GET  /pid?bundle=ID
  POST /crash?out=DIR[&match=REGEX]      pull crash reports (no erase)
  GET  /crashls
  POST /mark?text=...                    write a marker line into all/app/sys logs
"""
import asyncio
import datetime
import json
import os
import pathlib
import re
import sys
import traceback
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tvtunnel  # noqa: E402

from pymobiledevice3.services.os_trace import OsTraceService  # noqa: E402
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider  # noqa: E402
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot  # noqa: E402
from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl  # noqa: E402
from pymobiledevice3.services.crash_reports import CrashReportsManager  # noqa: E402

LOGDIR = pathlib.Path(os.environ.get("TVD_LOGDIR", pathlib.Path.home() / "tvtools" / "logs"))
PORT = int(os.environ.get("TVD_PORT", "8777"))
APP_EXE = os.environ.get("TVD_APP_EXE", "App")
APP_HINT = "com.local.tube"

SYS_PROC = re.compile(r"^(kernel|ReportCrash|osanalyticshelper|runningboardd|PineBoard|backboardd|sandboxd|"
                      r"mediaserverd|audiomxd|nsurlsessiond|networkd|symptomsd|watchdogd|jetsamd|memorystatus|"
                      r"installd|lsd|containermanagerd|amfid|launchd|logd|mediaplaybackd|AppleTVSettings)$")
SYS_MSG = re.compile(r"jetsam|memorystatus|memory pressure|highwater|EXC_|crash|Crash|SIGABRT|SIGSEGV|SIGKILL|"
                     r"terminat|Terminat|killed|watchdog|[Ss]andbox|deny\(|Metal|GPU|IOGPU|MTL|"
                     r"NSURLError|nw_|TLS|tcp_|timed out|Termination|exceeded|App\[|com\.local\.tube",)

state = {"tunnel": None, "rsd": None, "connected_at": None, "lines": 0, "app_lines": 0, "last_error": None,
         "app_pid": None}
files = {}


def now():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]


def write(names, line):
    for n in names:
        f = files[n]
        f.write(line + "\n")
        f.flush()


def fmt(e):
    proc = os.path.basename(e.filename or "") or "?"
    label = ""
    if e.label is not None:
        label = f" [{e.label.subsystem}:{e.label.category}]"
    ts = e.timestamp.strftime("%H:%M:%S.%f")[:-3] if e.timestamp else now()
    lvl = getattr(e.level, "name", str(e.level))
    msg = (e.message or "").replace("\n", "\\n")
    return proc, f"{ts} {proc}[{e.pid}] <{lvl}>{label} {msg}"


async def syslog_loop():
    rsd = state["rsd"]
    svc = OsTraceService(rsd)
    async for e in svc.syslog():
        proc, line = fmt(e)
        state["lines"] += 1
        targets = ["all"]
        is_app = proc == APP_EXE or APP_HINT in line
        if is_app:
            targets.append("app")
            lvl = getattr(e.level, "name", "")
            if "[com.local.tube:" in line or (proc == APP_EXE and lvl in ("Error", "Fault")):
                targets.append("tube")
            state["app_lines"] += 1
            if proc == APP_EXE:
                state["app_pid"] = e.pid
        if (SYS_PROC.match(proc) and SYS_MSG.search(line)) or (not is_app and SYS_MSG.search(line) and
                                                                ("App" in line or APP_HINT in line)):
            targets.append("sys")
        elif e.level is not None and getattr(e.level, "name", "") in ("Fault",) and not is_app:
            targets.append("sys")
        write(targets, line)


async def with_dvt(fn):
    async with DvtProvider(state["rsd"]) as dvt:
        return await fn(dvt)


async def do_shot(out):
    async def f(dvt):
        async with Screenshot(dvt) as s:
            return await s.get_screenshot()
    data = await with_dvt(f)
    p = pathlib.Path(out)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)
    return {"ok": True, "path": str(p), "bytes": len(data)}


async def do_launch(bundle):
    async def f(dvt):
        async with ProcessControl(dvt) as pc:
            return await pc.launch(bundle, kill_existing=True)
    pid = await with_dvt(f)
    write(["all", "app", "sys", "tube"], f"{now()} ===== tvd: launched {bundle} pid {pid} =====")
    return {"ok": True, "pid": pid}


async def do_pid(bundle):
    async def f(dvt):
        async with ProcessControl(dvt) as pc:
            return await pc.process_identifier_for_bundle_identifier(bundle)
    return {"ok": True, "pid": await with_dvt(f)}


async def do_kill(bundle):
    async def f(dvt):
        async with ProcessControl(dvt) as pc:
            pid = await pc.process_identifier_for_bundle_identifier(bundle)
            if pid:
                await pc.kill(pid)
            return pid
    return {"ok": True, "killed_pid": await with_dvt(f)}


async def do_crash(out, match=None):
    async with CrashReportsManager(state["rsd"]) as cm:
        await cm.pull(out, match=match, progress_bar=False)
    files_ = sorted(str(p) for p in pathlib.Path(out).rglob("*") if p.is_file())
    return {"ok": True, "out": out, "count": len(files_), "files": files_[-50:]}


async def do_crashls():
    async with CrashReportsManager(state["rsd"]) as cm:
        return {"ok": True, "entries": await cm.ls("/", depth=2)}


async def handle(reader, writer):
    try:
        req = await reader.readline()
        while True:
            h = await reader.readline()
            if h in (b"\r\n", b"\n", b""):
                break
        method, target, _ = req.decode().split(" ", 2)
        u = urlparse(target)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if state["rsd"] is None and u.path != "/status":
            res = {"ok": False, "error": "tunnel not connected", "last_error": state["last_error"]}
        elif u.path == "/status":
            res = {"ok": state["rsd"] is not None, **{k: v for k, v in state.items() if k not in ("tunnel", "rsd")}}
        elif u.path == "/shot":
            res = await asyncio.wait_for(do_shot(q.get("out", str(LOGDIR / f"shot-{now()}.png"))), 60)
        elif u.path == "/launch":
            res = await asyncio.wait_for(do_launch(q["bundle"]), 60)
        elif u.path == "/pid":
            res = await asyncio.wait_for(do_pid(q["bundle"]), 30)
        elif u.path == "/kill":
            res = await asyncio.wait_for(do_kill(q["bundle"]), 30)
        elif u.path == "/crash":
            res = await asyncio.wait_for(do_crash(q["out"], q.get("match")), 300)
        elif u.path == "/crashls":
            res = await asyncio.wait_for(do_crashls(), 60)
        elif u.path == "/mark":
            write(["all", "app", "sys", "tube"], f"{now()} ===== MARK: {q.get('text', '')} =====")
            res = {"ok": True}
        else:
            res = {"ok": False, "error": f"unknown path {u.path}"}
    except Exception as e:  # report every failure to the caller
        res = {"ok": False, "error": f"{type(e).__name__}: {e}", "trace": traceback.format_exc()[-1500:]}
    body = json.dumps(res, default=str).encode()
    writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
                 str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
    await writer.drain()
    writer.close()


async def tunnel_loop():
    while True:
        try:
            t, rsd = await tvtunnel.open_tunnel()
            state.update(tunnel=t, rsd=rsd, connected_at=now(), last_error=None)
            write(["all", "app", "sys"], f"{now()} ===== tvd: tunnel up (tvOS {rsd.product_version}) =====")
            await syslog_loop()
            raise RuntimeError("syslog stream ended")
        except Exception as e:
            state["last_error"] = f"{type(e).__name__}: {e}"
            write(["all", "sys"], f"{now()} ===== tvd: tunnel error {state['last_error']} =====")
        finally:
            t = state.get("tunnel")
            state.update(tunnel=None, rsd=None)
            if t is not None:
                try:
                    await asyncio.wait_for(t.aclose(), 5)
                except Exception:
                    pass
        await asyncio.sleep(5)


async def main():
    LOGDIR.mkdir(parents=True, exist_ok=True)
    for n in ("all", "app", "sys", "tube"):
        files[n] = open(LOGDIR / f"{n}.log", "a", buffering=1)
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    async with server:
        await asyncio.gather(server.serve_forever(), tunnel_loop())


if __name__ == "__main__":
    asyncio.run(main())
