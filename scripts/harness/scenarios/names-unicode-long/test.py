"""Non-ASCII and over-long names arrive as valid text and never break the session."""
from reamo_client import Client

with Client() as c:
    names = [t["n"] for t in c.wait_event("trackSkeleton")["payload"]["tracks"]]
    print("track names:", [n[:24] for n in names])
    assert names[1] == "Bën — Vocals 🎤" and names[2] == "ギター", names
    assert names[3].startswith("Long name Long name"), names[3][:40]
    m = c.wait_event("markers")["payload"]["markers"]
    r = c.wait_event("regions")["payload"]["regions"]
    assert m and m[0]["name"].startswith("Chorus 💥"), m
    assert r and r[0]["name"].startswith("Brücke"), r
    r = c.command("track/subscribe", range={"start": 0, "end": 3})
    assert r["success"], r
    c.wait_event("tracks")
