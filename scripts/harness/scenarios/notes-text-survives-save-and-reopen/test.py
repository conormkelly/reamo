"""Notes typed on the phone come back as typed: through REAPER, a project save
and a reopen. Line breaks, unicode, and lines that start with characters the
.rpp format uses itself (| < >) included.
"""
import json

from reamo_client import Client, reaper

TYPED = "Setlist 🎸 — Zürich\nVerse 1: \"quiet\"\n\tbridge\\coda\n| bar 12 tacet\n<intro> x2\n> fade\n\nend"
GET = "return select(1, reaper.GetSetProjectNotes(0, false, ''))"


def norm(s):
    return s.replace("\r\n", "\n")


# First: does REAPER itself keep such text across save + reopen? (oracle)
probe = "| pipe\n<lt\n>gt\nplain"
reaper(f"reaper.GetSetProjectNotes(0, true, {json.dumps(probe)})")
reaper('reaper.Main_SaveProjectEx(0, "/tmp/notes_probe.rpp", 0)')
reaper('reaper.Main_openProject("noprompt:/tmp/notes_probe.rpp")')
reaper_kept = norm(reaper(GET))
print("REAPER alone, after save+reopen:", repr(reaper_kept))

with Client() as c:
    r = c.command("projectNotes/set", notes=TYPED)
    assert r["success"], r
    in_reaper = norm(reaper(GET))
    echoed = norm(r["payload"]["notes"])
    print("typed :", repr(TYPED))
    print("REAPER:", repr(in_reaper))
    reaper('reaper.Main_SaveProjectEx(0, "/tmp/notes_rt.rpp", 0)')
    reaper('reaper.Main_openProject("noprompt:/tmp/notes_rt.rpp")')
    after = norm(reaper(GET))
    got = norm(c.command("projectNotes/get")["payload"]["notes"])
    print("reopen:", repr(after))
    problems = []
    if in_reaper != TYPED:
        problems.append(f"REAPER holds {in_reaper!r}, not what was typed")
    if echoed != in_reaper:
        problems.append(f"set response {echoed!r} differs from REAPER {in_reaper!r}")
    if after != in_reaper:
        problems.append(f"save+reopen changed the notes: {after!r}")
    if got != after:
        problems.append(f"projectNotes/get {got!r} differs from REAPER {after!r}")
    assert not problems, "\n".join(problems)
