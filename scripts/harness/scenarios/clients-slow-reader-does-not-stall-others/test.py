"""A client that stops reading (a phone gone to sleep with the socket still
open, a stalled Wi-Fi link) must not stall REAPER or the other clients.

The stalled client asks for large responses and full track updates, then
never reads. Meanwhile the transport plays; the healthy client must keep
getting ~30 Hz transport events and quick command responses, and REAPER's
main thread must keep running.
"""
import time

from reamo_client import Client, reaper

with Client() as stalled, Client() as phone:
    phone.wait_event("transport"); stalled.wait_event("transport")
    stalled.command("track/subscribe", range={"start": 0, "end": 8})
    for i in range(6):  # ~700 KB each, never read
        stalled.send({"type": "command", "command": "action/getActions", "id": f"big{i}"})
    reaper("reaper.OnPlayButton()")

    worst_cmd = worst_rpc = 0.0
    t0 = time.time()
    n0 = len(phone.events)
    while time.time() - t0 < 8:
        a = time.time()
        r = phone.command("debug/memoryStats", timeout=3)
        assert r["success"], r
        worst_cmd = max(worst_cmd, time.time() - a)
        a = time.time()
        reaper("return reaper.GetPlayPosition()")
        worst_rpc = max(worst_rpc, time.time() - a)
        phone.drain(0.2)
    secs = time.time() - t0
    transport = sum(1 for name, _ in phone.events[n0:] if name in ("transport", "tt"))
    reaper("reaper.OnStopButton()")
    print(f"healthy client: {transport / secs:.1f} transport events/s, worst command {worst_cmd * 1000:.0f} ms, "
          f"worst REAPER rpc {worst_rpc * 1000:.0f} ms")
    assert transport / secs > 10, "transport events to the healthy client dried up"
    assert worst_cmd < 1.0 and worst_rpc < 1.0, "REAPER or the healthy client stalled"
