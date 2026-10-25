"""A large session reaches a new client completely: skeleton, markers, regions, items."""
from reamo_client import Client, reaper

with Client(timeout=10) as c:
    skeleton = c.wait_event("trackSkeleton")["payload"]["tracks"]
    markers = c.wait_event("markers")["payload"]["markers"]
    regions = c.wait_event("regions")["payload"]["regions"]
    items = c.wait_event("items")["payload"]["items"]
    print(f"skeleton={len(skeleton)} markers={len(markers)} regions={len(regions)} items={len(items)}")
    assert len(skeleton) == 301, len(skeleton)
    assert len(markers) == 200 and len(regions) == 200, (len(markers), len(regions))
    # Item polling is capped at 512 by design (MAX_ITEMS); all of those must arrive.
    assert len(items) == 512, len(items)
    r = c.command("track/subscribe", range={"start": 0, "end": 63})
    assert r["success"], r
    tracks = c.wait_event("tracks")["payload"]["tracks"]
    assert len(tracks) == 64, len(tracks)
    c.drain(2)  # a few polling cycles at this size
    # The items past the cap are missing on phones; the log must say so, once.
    log = reaper("local f = io.open(reaper.GetResourcePath() .. '/Logs/reamo.log'); local s = f:read('a'); f:close(); return s")
    assert log.count("The project has 512 or more items; phones get the first 512") == 1, log[-3000:]
