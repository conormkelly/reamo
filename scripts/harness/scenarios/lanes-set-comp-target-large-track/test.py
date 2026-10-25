"""Setting the comp target lane on a big comped track keeps every item.

lanes/setCompTarget rewrites the track's state chunk. On a track whose chunk
is larger than the extension's buffer it must either do the whole job or
refuse; it must never write back a cut-off chunk.
"""
import time
from reamo_client import Client, oracle, reaper

o = oracle()
assert int(o["chunk_bytes"]) > 65536, o
ITEMS = int(o["items"])

with Client() as c:
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    g = skel[1]["g"]
    deadline = time.time() + 3
    while True:
        st = c.command("lanes/getState", trackGuid=g)
        if st["success"] or time.time() > deadline:
            break
        time.sleep(0.1)
    print("getState:", {k: v for k, v in st.get("payload", {}).items() if k != "lanes"} or st)
    r = c.command("lanes/setCompTarget", trackGuid=g, laneIndex=1)
    print("setCompTarget:", r)
    c.drain(0.3)
    n = reaper("return reaper.CountTrackMediaItems(reaper.GetTrack(0, 0))")
    lanerec = reaper('local _, ch = reaper.GetTrackStateChunk(reaper.GetTrack(0, 0), "", false); return ch:match("LANEREC[^\\n]*"), #ch')
    print(f"items {ITEMS} -> {n}; {lanerec}")
    assert n == ITEMS, f"setCompTarget lost {ITEMS - n} of {ITEMS} items"
    if r["success"]:
        assert lanerec[0].split()[2] == "1", f"reported success but LANEREC is {lanerec[0]!r}"
