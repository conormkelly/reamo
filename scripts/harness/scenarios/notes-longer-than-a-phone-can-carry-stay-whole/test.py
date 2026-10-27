"""Project notes longer than a phone can carry must reach it marked as cut
off, and a save from a phone must not replace them with the part it got:
the rest of the lyrics would be gone."""
from reamo_client import Client, reaper

NOTES = 'return reaper.GetSetProjectNotes(0, false, "")'

full = reaper(NOTES)
assert len(full.encode()) > 65536, len(full.encode())
with Client() as c:
    r = c.command("projectNotes/subscribe")
    assert r["success"], r
    got = r["payload"]
    assert got.get("truncated") is True, f"cut-off notes not flagged: {sorted(got)}"
    assert full.startswith(got["notes"]) and 60000 < len(got["notes"].encode()) <= 65536, len(got["notes"])

    r = c.command("projectNotes/get")
    assert r["success"] and r["payload"].get("truncated") is True, r.get("error")

    # The user trims a verse and saves, from the part they were shown.
    edited = got["notes"][:50000] + "\nchorus x2"
    r = c.command("projectNotes/set", notes=edited)
    assert not r["success"] and r["error"]["code"] == "NOTES_TOO_LONG_TO_EDIT", r
    assert reaper(NOTES) == full, "a refused save changed REAPER's notes"

    # Once the notes are short enough, phones edit them as before.
    reaper('reaper.GetSetProjectNotes(0, true, "Setlist\\n1. Intro")')
    r = c.command("projectNotes/get")
    assert r["success"] and "truncated" not in r["payload"], r
    r = c.command("projectNotes/set", notes="Setlist\n1. Intro\n2. Verse")
    assert r["success"], r
    assert reaper(NOTES) == "Setlist\r\n1. Intro\r\n2. Verse", repr(reaper(NOTES))
print("ok: notes over 64 KB reach phones flagged as cut off, and a phone can't save over them")
