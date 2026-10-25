"""tuner/subscribe answers with valid JSON carrying the track's real name.

TunerView subscribes and the response payload includes trackName. Names
with quotes or backslashes, and long non-ASCII names, must come back intact.
"""
import json
import time
import reamo_client
from reamo_client import Client, reaper

_loads = json.loads


def checked_loads(payload, **kw):
    try:
        return _loads(payload, **kw)
    except ValueError as e:
        raise AssertionError(f"frame is not valid JSON ({e}): {payload[:220]!r}") from None


reamo_client.json.loads = checked_loads

with Client() as c:
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    problems = []
    for idx in (1, 2):
        want = reaper(f"local _, n = reaper.GetTrackName(reaper.GetTrack(0, {idx - 1})); return n")
        try:
            r = c.command("tuner/subscribe", trackGuid=skel[idx]["g"])
        except AssertionError as e:
            problems.append(f"track {idx} {want!r}: {e}")
            continue
        got = r.get("payload", {}).get("trackName") if r["success"] else r.get("error")
        print(f"track {idx}: REAPER {want!r}\n         tuner {got!r}")
        if got != want:
            problems.append(f"track {idx}: trackName {got!r}, REAPER {want!r}")
    assert not problems, "\n".join(problems)
