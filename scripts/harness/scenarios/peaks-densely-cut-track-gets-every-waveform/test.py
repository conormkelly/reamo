"""A track cut into many short items gets a waveform for every one of them.

The peaks reply's buffer was sized as one item's tiles per track. Every
item in view brings tiles of its own, so a densely edited track overflowed
it and the items past that point were drawn without a waveform.
"""
import importlib.util
import os
import time

from reamo_client import Client

spec = importlib.util.spec_from_file_location(
    "zoom", os.path.join(os.path.dirname(__file__), "..", "peaks-zoom-viewport-matches-reaper", "test.py"))
# Only the frame decoder is wanted; importing the module would run its test.
src = open(spec.origin).read()
ns = {}
exec(src[:src.index("def next_frame")], ns)
tiles = ns["tiles"]

with Client(timeout=10) as c:
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    r = c.command("peaks/subscribe", range={"start": 1, "end": 1},
                  viewport={"start": 0, "end": 30, "widthPx": 1200})
    assert r["success"], r
    deadline = time.time() + 5
    while not c.binary and time.time() < deadline:
        c.drain(0.2)
    assert c.binary, "no peaks frame"
    got = tiles(c.binary[-1])
    guids = {t["guid"] for t in got}
    print(f"{len(got)} tiles for {len(guids)} items")
    assert len(guids) == 120, f"only {len(guids)} of 120 items got a waveform"
