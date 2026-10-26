"""transport/record captures a take on the armed track; transport/stopAndDelete throws it away.

With REAPER's dummy audio device, record for ~1.5 s from the phone and
stop: the armed track gains an item of about that length and the items
event shows it. Record again and stopAndDelete: no new item, REAPER's item
count is back where it was, and the transport shows stopped.
"""
import time

from reamo_client import Client, reaper

ITEMS = """
local out = {}
for i = 0, reaper.CountMediaItems(0) - 1 do
  local it = reaper.GetMediaItem(0, i)
  out[#out + 1] = {reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH")}
end
return out
"""


def wait_play_state(c, want, timeout=2.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        c.drain(0.05)
        if c.latest_event("transport")["payload"]["playState"] == want:
            return True
    return False


def client_item_count(c):
    ev = c.latest_event("items")
    return len(ev["payload"]["items"]) if ev else 0


with Client() as c:
    c.wait_event("items")
    assert reaper("return reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, 0), 'I_RECARM')") == 1
    problems = []

    c.fire("transport/seek", position=2.0)
    c.drain(0.2)
    c.fire("transport/record")
    assert wait_play_state(c, 5), f"never saw recording: {c.latest_event('transport')['payload']}"
    assert reaper("return reaper.GetPlayState()") == 5
    c.drain(1.5)
    c.fire("transport/stop")
    assert wait_play_state(c, 0), "never saw stopped after recording"
    items = reaper(ITEMS)
    print("  after record+stop, REAPER items:", items)
    if len(items) != 1 or abs(items[0][0] - 2.0) > 0.05 or not 1.2 < items[0][1] < 2.5:
        problems.append(f"record 1.5 s from 2.0 s should leave one item there, REAPER has {items}")
    deadline = time.time() + 2
    while client_item_count(c) != len(items) and time.time() < deadline:
        c.drain(0.2)
    if client_item_count(c) != len(items):
        problems.append(f"items event shows {client_item_count(c)} items, REAPER {len(items)}")

    c.fire("transport/seek", position=6.0)
    c.drain(0.2)
    c.fire("transport/record")
    assert wait_play_state(c, 5), "never saw the second recording start"
    c.drain(1.0)
    c.fire("transport/stopAndDelete")
    assert wait_play_state(c, 0), f"stopAndDelete did not stop: {c.latest_event('transport')['payload']}"
    c.drain(0.6)
    after = reaper(ITEMS)
    print("  after record+stopAndDelete, REAPER items:", after)
    if after != items:
        problems.append(f"stopAndDelete should discard the take: before {items}, after {after}")
    if client_item_count(c) != len(after):
        problems.append(f"items event shows {client_item_count(c)} items, REAPER {len(after)}")
    files = reaper("""local dir, out, i = harness.mkdir("/tmp/rec"), {}, 0
        while reaper.EnumerateFiles(dir, i) do out[#out + 1] = reaper.EnumerateFiles(dir, i); i = i + 1 end
        return out""")
    print("  files in record path:", files)
    if len([f for f in files if f.lower().endswith(".wav")]) != 1:
        problems.append(f"stopAndDelete should delete the discarded take's file; record path holds {files}")
    assert not problems, "\n".join(problems)
