"""An edit on any subscribed track reaches the phone watching it, however
many tracks the phones subscribe to between them.

Phone A subscribes to all 160 tracks, phone B to the last 32 (129..160).
REAmo checks the tracks the phones watch for changes, and sends every
phone fresh tiles when one changes. With more subscribed tracks than one
tick's check reads (128), every track must still be checked in turn.

Each of B's tracks has its take reversed in REAPER, one at a time. After
each edit B must get a peaks frame whose tiles for that take match
REAPER's own peaks for it: the staircase played backwards.
"""
import time

from reamo_client import Client, reaper
import peaks_check as pk

TRACKS = 160
WATCHED = range(129, TRACKS + 1)  # B's tracks, 1-based as REAmo numbers them
DOWN = (0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1)
VIEW = {"start": 0, "end": 14, "widthPx": 1400}


def name(idx):
    return f"t{idx:03d}"


def reverse(idx):
    reaper(f"harness.reverse_take(reaper.GetTrackMediaItem(reaper.GetTrack(0, {idx - 1}), 0)); "
           "reaper.UpdateArrange()")


with Client() as a, Client() as b:
    a.wait_event("items")
    assert reaper("return reaper.CountTracks(0)") == TRACKS
    r = a.command("peaks/subscribe", range={"start": 1, "end": TRACKS}, viewport=VIEW)
    assert r["success"], r
    r = b.command("peaks/subscribe", range={"start": WATCHED[0], "end": WATCHED[-1]}, viewport=VIEW)
    assert r["success"], r
    pk.wait_tiles(b)
    pk.drain_until_quiet(b)
    a.drain(0.1)

    missed, wrong, evidence = [], [], {}
    for idx in WATCHED:
        pk.drain_until_quiet(b, quiet=0.4)
        a.drain(0.05)
        n = len(b.binary)
        reverse(idx)
        deadline = time.time() + 3.0
        while len(b.binary) == n and time.time() < deadline:
            b.drain(0.1)
        b.drain(0.3)
        a.drain(0.05)
        if len(b.binary) == n:
            missed.append(name(idx))
            print(f"{name(idx)}: no peaks frame within 3 s of the edit")
            continue
        profiles, bad = pk.compare(pk.tiles_since(b, n), [name(idx)])
        evidence[name(idx)] = profiles
        got = profiles[name(idx)][0]
        if got is None or not pk.near(got["max"][0], pk.steps(*DOWN)):
            wrong.append(name(idx))
            print("\n".join(bad))
        else:
            print(f"{name(idx)}: reversed waveform arrived ({len(b.binary) - n} frames)")
    pk.save("profiles", evidence)
    assert not missed and not wrong, (
        f"after reversing its take, phone B got no peaks frame for {len(missed)} of its "
        f"{len(WATCHED)} tracks ({', '.join(missed)}) and stale tiles for {len(wrong)} "
        f"({', '.join(wrong)})")
