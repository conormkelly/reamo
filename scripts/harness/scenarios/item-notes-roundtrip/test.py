"""Notes edited from a client reach REAPER intact: full length, real newlines, quotes."""
from reamo_client import Client

note = 'Take 3 was the keeper.\nComp from bar 12 — "watch the breath".\n' + ("x" * 5000)
with Client() as c:
    r = c.command("item/setNotes", trackIdx=1, itemIdx=0, notes=note)
    assert r["success"], r
    got = c.command("item/getNotes", trackIdx=1, itemIdx=0)
    assert got["success"], got
    back = got["payload"]["notes"]
    print(f"set {len(note)} chars, read back {len(back)}; newline intact={chr(10) in back}")
    assert back == note, f"round trip changed the note (first diff at {next((i for i,(a,b) in enumerate(zip(note, back)) if a != b), min(len(note), len(back)))})"
