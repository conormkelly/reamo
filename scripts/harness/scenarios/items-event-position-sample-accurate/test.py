"""The items event carries item positions and lengths to the sample.

NavigateItemInfoBar's nudge sends moveByGuid with `item.position + delta`
from the items event, so a rounded position moves the item by the wrong
amount and loses a sample-accurate edit.
"""
import time
from reamo_client import Client, reaper

with Client() as c:
    it = c.wait_event("items")["payload"]["items"][0]
    pos, length = reaper('local it = reaper.GetMediaItem(0, 0); '
                         'return reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH")')
    print(f"REAPER {pos!r} / {length!r}; event {it['position']!r} / {it['length']!r}")
    # A nudge of +0.5 s as the phone computes it.
    c.fire("item/moveByGuid", guid=it["guid"], position=it["position"] + 0.5)
    time.sleep(0.3)
    after = reaper('return reaper.GetMediaItemInfo_Value(reaper.GetMediaItem(0, 0), "D_POSITION")')
    print(f"after +0.5 s nudge: {after!r} (moved {after - pos:+.7f} s)")
    assert abs(it["position"] - pos) < 0.5 / 48000, f"event position {it['position']} vs REAPER {pos}"
    assert abs(it["length"] - length) < 0.5 / 48000, f"event length {it['length']} vs REAPER {length}"
