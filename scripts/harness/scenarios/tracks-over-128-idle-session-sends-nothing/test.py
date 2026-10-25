"""A session with more than 128 tracks that nobody touches sends no track-list updates.

The track list (trackSkeleton) is broadcast only when it changes. A project
past the 128-track arrays used to read as changed on every low-tier poll, so
an idle session rebroadcast the whole list every second, forever.
"""
from reamo_client import Client

with Client(timeout=10) as c:
    skeleton = c.wait_event("trackSkeleton")["payload"]["tracks"]
    assert len(skeleton) == 141, len(skeleton)  # master + 140
    c.drain(1.5)  # let startup settle
    c.events.clear()
    c.drain(4)  # four low-tier polls with nothing changing
    resent = sum(1 for name, _ in c.events if name == "trackSkeleton")
    print(f"trackSkeleton events while idle: {resent}")
    assert resent == 0, resent
