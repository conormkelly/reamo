"""A reversed take shows its waveform backwards, as REAPER does.

Reversing a take wraps its source in a reversed SECTION (RV1-151 asked
whether REAmo, which never unwraps it, gets this right). REAPER draws the
take's peaks from GetMediaItemTake_Peaks, which plays it backwards; REAmo
asks the same API, so its tiles run from the file's loudest second down.
A start offset counts from the reversed start, and a reversed section plays
just that section backwards.
"""
from reamo_client import Client
import peaks_check as pk

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    profiles, bad = pk.compare(tiles, ["reversed", "reversed, offset 2 s", "reversed section 2-5 s"])
    pk.save("profiles", profiles)
    pk.screenshot_arrange("reaper-arrange")

    want = {"reversed": pk.steps(0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1),
            "reversed, offset 2 s": pk.steps(0.6, 0.5, 0.4, 0.3, 0.2, 0.1),
            "reversed section 2-5 s": pk.steps(0.5, 0.4, 0.3)}
    for name, levels in want.items():
        got = profiles[name][1]["max"][0]
        assert pk.near(got, levels), f"REAPER's peaks for {name!r}: {pk.fmt(got)}, expected {pk.fmt(levels)}"
    assert not bad, "\n".join(bad)
