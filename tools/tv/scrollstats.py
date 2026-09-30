#!/usr/bin/env python3
"""scrollstats — counts what the app did between tvd marks, from the new bytes of a log only.

  size=$(stat -c %s ~/tvtools/logs/app.log)      # before the test
  ... keyrun.py "mark:home_down down*20@0.4 mark:home_up up*20@0.4 mark:end"
  scrollstats.py ~/tvtools/logs/app.log "$size"

The logs grow by gigabytes, so this never reads a file from the start. Per segment (text between
two marks) it prints: focus moves (the focus sound tvOS plays for each one), image and API
requests finished (CFNetwork task summaries) and how many came from URLCache, bytes received,
the UIKit preference lookups that flood the log while lists scroll, main-thread hangs, memory
warnings and SwiftUI runtime warnings.

The TV's log relay drops lines when the app logs thousands per second (those UIKit lookups do
while a grid scrolls), so every count is a lower bound: compare focus_moves with the number of
presses to see how complete a segment is. Tube's own "images:" line (ImagePipeline, every 10 s
while images load) is the reliable count of image loads.
"""
import bisect
import re
import sys
from collections import Counter, OrderedDict

PATTERNS = OrderedDict([
    ("focus_moves", re.compile(r"Playing focus system sound")),
    ("tasks", re.compile(r"CFNetwork:Summary\] Task .* summary for task success")),
    ("cache_hits", re.compile(r"summary for task success .*cache_hit=true")),
    ("task_fail", re.compile(r"summary for task (?!success)")),
    ("uikit_prefs", re.compile(r"found no value for key .*Domain: com\.apple\.UIKit")),
    ("localized", re.compile(r"CFBundle:strings\] Bundle: .*table: Localizable")),
    # HangTracer's own lines, minus its notes about the app going to and from the background.
    ("hangs", re.compile(r"Hang detected|hangtracer:\](?!.*(?:transitioned to|rollingFGTimestamp|no longer foreground))")),
    ("memory", re.compile(r"didReceiveMemoryWarning|memorystatus|jetsam|[Mm]emory pressure|footprint")),
    ("swiftui_warn", re.compile(r"AttributeGraph|Modifying state during view update|Bound preference|"
                                r"multiple times per frame|Publishing changes from within view updates|"
                                r"LazyVGrid|LazyVStack|cycle detected")),
    # Tube's own failures (its "images:" stats line says "0 failed", which isn't one).
    ("tube_errors", re.compile(r"\[com\.local\.tube:[a-z]+\] (?!images: ).*(fail|error)", re.I)),
])
IMAGES = re.compile(r"\[com\.local\.tube:images\] (images: .*)")
BYTES = re.compile(r"response_bytes=(\d+)")
MARK = re.compile(r"===== MARK: (.*) =====")
TIME = re.compile(r"^(\d\d:\d\d:\d\d\.\d{3})")


def main(path, start, end=None):
    with open(path, "rb") as f:
        f.seek(start)
        data = f.read((end - start) if end else -1)
    # The TV's lines reach the file seconds late (the stream lags when the app logs heavily),
    # while tvd writes a mark the moment it's asked, so lines are sorted into segments by their
    # own timestamp (TV and laptop clocks both follow NTP), not by where they are in the file.
    marks = [("", "(before first mark)")]
    lines = []
    for raw in data.decode("utf-8", "replace").splitlines():
        m = MARK.search(raw)
        if m:
            stamp = re.search(r"(\d\d:\d\d:\d\d\.\d{3}) =====", raw)
            marks.append((stamp.group(1) if stamp else "", m.group(1)))
            continue
        t = TIME.match(raw)
        if t:
            lines.append((t.group(1), raw))
    marks.sort()
    segments = [[name, Counter(), None, None, []] for _, name in marks]
    starts = [t for t, _ in marks]
    for stamp, raw in lines:
        seg = segments[bisect.bisect_right(starts, stamp) - 1]
        seg[2] = min(seg[2] or stamp, stamp)
        seg[3] = max(seg[3] or stamp, stamp)
        i = IMAGES.search(raw)
        if i:
            seg[4].append(f"{stamp} {i.group(1)}")
        for name, rx in PATTERNS.items():
            if rx.search(raw):
                seg[1][name] += 1
                if name == "tasks":
                    b = BYTES.search(raw)
                    if b:
                        seg[1]["kbytes"] += int(b.group(1)) / 1024
    cols = list(PATTERNS) + ["kbytes"]
    print("segment".ljust(22) + "time".ljust(20) + "".join(c[:12].rjust(13) for c in cols))
    for name, counts, first, last, _ in segments:
        if not counts and name.startswith("("):
            continue
        span = f"{first or '-'}–{(last or '-')[3:]}"
        print(name[:21].ljust(22) + span[:19].ljust(20) + "".join(str(int(counts[c])).rjust(13) for c in cols))
    for name, _, _, _, images in segments:
        for line in images:
            print(f"{name[:21]}: {line}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else None)
