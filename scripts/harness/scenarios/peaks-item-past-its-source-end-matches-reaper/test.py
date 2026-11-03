"""An item that runs on past its audio shows the audio, then a flat line, as REAPER does.

An item can run on past the audio its take plays: looping off and the item
longer than its file, or slipped or sped up without shortening it. REAPER
draws the audio, then a flat line. GetMediaItemTake_Peaks then returns
fewer peaks than asked for, and writes its block of minimums where it would
start for the count asked for (after `asked` maximums), leaving the gap
before it untouched.

REAmo reads the minimums from there too, so both halves of the waveform
match REAPER's: no slot REAPER never wrote reaches a phone, and the bottom
half isn't shifted. The oracle reads REAPER's minimums the same way, and
this scenario checks that layout too: fewer peaks than asked for, silence
after them, and minimums that mirror the maximums.
"""
from reamo_client import Client
import peaks_check as pk

GAPPED = ["12 s item, 8 s file", "slipped 2 s, 8 s item", "rate 2, 6 s item"]

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    profiles, bad = pk.compare(tiles, GAPPED + ["whole file"])
    pk.save("profiles", profiles)
    pk.save("reamo-tiles", tiles)
    pk.screenshot_arrange("reaper-arrange")

    for name in GAPPED:
        got, want = profiles[name]
        assert got, f"REAmo sent no tiles for {name!r}"
        # REAPER: fewer peaks than asked, then silence, and its minimums
        # (read at the count asked for) mirror its maximums.
        assert want["got"] < want["asked"], f"{name}: REAPER returned {want['got']} of {want['asked']} peaks"
        audio_s = want["got"] / 200.0
        nb_audio = round(audio_s * 2)
        assert max(want["max"][0][nb_audio:]) < 0.01, f"{name}: REAPER's peaks after the audio: {pk.fmt(want['max'][0])}"
        assert pk.near([-v for v in want["min"][0]], want["max"][0]), \
            f"{name}: REAPER's minimums don't mirror its maximums:\n  max {pk.fmt(want['max'][0])}\n  min {pk.fmt(want['min'][0])}"
        print(f"{name}: audio {audio_s:g} s of {want['length']:g} s")
        print(f"  REAmo  min {pk.fmt(got['min'][0])}\n  REAPER min {pk.fmt(want['min'][0])}")

    # REAmo: both halves match REAPER's, for every item and the control
    # whose item ends with its audio.
    assert not bad, "\n".join(bad)
