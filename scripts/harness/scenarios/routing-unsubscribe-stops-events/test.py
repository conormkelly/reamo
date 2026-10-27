"""Closing the routing / FX / param views stops their events; the other phone keeps its own.

Phone A and B both have Vocals' routing, FX chain and EQ params open. A closes
them (routing/unsubscribe, trackFx/unsubscribe, trackFxParams/unsubscribe).
Changes made in REAPER afterwards must reach B and not A. A re-subscribing
must get a fresh event straight away even though nothing changed.
"""
import time
from reamo_client import Client, reaper

KINDS = ("routing_state", "trackFxChain", "trackFxParams")


def change(i):
    reaper(f"""
        local t = reaper.GetTrack(0, 0)
        reaper.SetTrackSendInfo_Value(t, 0, 0, 'D_VOL', {0.5 + i / 10})
        reaper.TrackFX_SetEnabled(t, 0, {'false' if i % 2 else 'true'})
        reaper.TrackFX_SetParamNormalized(t, 0, 0, {0.25 + i / 8})
    """)


def subscribe(c, g, fx=None):
    assert c.command("routing/subscribe", trackGuid=g)["success"]
    assert c.command("trackFx/subscribe", trackGuid=g)["success"]
    if fx:
        assert c.command("trackFxParams/subscribe", trackGuid=g, fxGuid=fx, indices=[0])["success"]


def kinds_seen(c, seconds):
    c.events.clear()
    c.drain(seconds)
    return {n for n, _ in c.events if n in KINDS}


with Client() as a, Client() as b:
    g = a.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    subscribe(a, g)
    fx = a.wait_event("trackFxChain")["payload"]["fx"][0]["fxGuid"]
    subscribe(a, g, fx)
    subscribe(b, g, fx)
    a.drain(0.5); b.drain(0.5)
    change(1)
    assert kinds_seen(a, 0.8) == set(KINDS)
    for cmd in ("routing/unsubscribe", "trackFx/unsubscribe", "trackFxParams/unsubscribe"):
        assert a.command(cmd)["success"], cmd
    a.drain(0.3)
    change(2)
    seen_a, seen_b = kinds_seen(a, 0.8), kinds_seen(b, 0.01)
    b_events = {n for n, _ in b.events if n in KINDS}
    b.drain(0.8)
    b_events |= {n for n, _ in b.events if n in KINDS}
    print("after A unsubscribes: A got", sorted(seen_a), "B got", sorted(b_events))
    assert not seen_a, f"A still receives {seen_a} after unsubscribing"
    assert b_events == set(KINDS), f"B lost {set(KINDS) - b_events}"
    a.events.clear()
    subscribe(a, g, fx)
    a.drain(0.8)
    got = {n for n, _ in a.events if n in KINDS}
    print("A re-subscribes, nothing changed: got", sorted(got))
    assert got == set(KINDS), f"re-subscribing gave only {got}"
