"""lanes/getState on a track with a long lane name returns cleanly."""
from reamo_client import Client, skip_before_lanes

with Client() as c:
    skip_before_lanes(c, "lanes/getState", trackIdx=1)
    r = c.command("lanes/getState", trackIdx=1)
    print(f"lanes/getState success={r['success']}")
    assert r["success"], r
