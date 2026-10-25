"""lanes/getState on a track with a long lane name returns cleanly."""
from reamo_client import Client

with Client() as c:
    r = c.command("lanes/getState", trackIdx=1)
    print(f"lanes/getState success={r['success']}")
    assert r["success"], r
