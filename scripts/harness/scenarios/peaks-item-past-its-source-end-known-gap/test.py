"""Known gap (RV1-151): past the end of its audio, an item's lower waveform half is drawn late.

An item can run on past the audio its take plays: looping off and the item
longer than its file, or slipped or sped up without shortening it. REAPER
draws the audio, then a flat line. GetMediaItemTake_Peaks then returns
fewer peaks than asked for, and writes its block of minimums where it would
start for the count asked for (after `asked` maximums), leaving the gap
before it untouched.

REAmo reads the minimums from just after the peaks returned. So on a phone
the top half of the waveform is right, but the bottom half starts with
whatever was in REAmo's buffer and shows the audio late by the length past
its end.

This scenario pins both: REAPER's layout (the oracle reads the minimums at
the count asked for, and they mirror the maximums), and REAmo's misread.
When REAmo reads the minimums at the count asked for, the misread assertion
fails: make it assert a match instead.
"""
from reamo_client import Client
import peaks_check as pk

GAPPED = ["12 s item, 8 s file", "slipped 2 s, 8 s item", "rate 2, 8 s item"]

with Client() as c:
    c.wait_event("items")
    tiles = pk.subscribe_all(c)
    profiles, bad = pk.compare(tiles, GAPPED + ["whole file"])
    pk.save("profiles", profiles)
    pk.save("reamo-tiles", tiles)
    pk.screenshot_arrange("reaper-arrange")

    # The control, whose item ends with its audio, matches.
    assert not [b for b in bad if b.startswith("whole file")], "\n".join(bad)

    for name in GAPPED:
        got, want = profiles[name]
        assert got, f"REAmo sent no tiles for {name!r}"
        # REAPER: fewer peaks than asked, then silence, and its minimums
        # (read at the count asked for) mirror its maximums.
        assert want["got"] < want["asked"], f"{name}: REAPER returned {want['got']} of {want['asked']} peaks"
        audio_s = want["got"] / 200.0
        nb_audio = int(audio_s * 2)
        assert max(want["max"][0][nb_audio:]) < 0.01, f"{name}: REAPER's peaks after the audio: {pk.fmt(want['max'][0])}"
        assert pk.near([-v for v in want["min"][0]], want["max"][0]), \
            f"{name}: REAPER's minimums don't mirror its maximums:\n  max {pk.fmt(want['max'][0])}\n  min {pk.fmt(want['min'][0])}"

        # REAmo: the top half matches REAPER's.
        assert pk.near(got["max"][0], want["max"][0]), \
            f"{name}: REAmo's maximums {pk.fmt(got['max'][0])}, REAPER's {pk.fmt(want['max'][0])}"
        # Known gap: its bottom half is REAPER's, late by the time past the audio.
        late = int((want["length"] - audio_s) * 2)
        shifted = want["min"][0][:nb_audio - late]
        mine = got["min"][0][late:nb_audio]
        print(f"{name}: audio {audio_s:g} s of {want['length']:g} s; REAmo's minimums run {late / 2:g} s late")
        print(f"  REAmo  min {pk.fmt(got['min'][0])}\n  REAPER min {pk.fmt(want['min'][0])}")
        assert not pk.near(got["min"][0], want["min"][0]) and pk.near(mine, shifted), \
            f"{name}: REAmo's minimums no longer run {late / 2:g} s late. If they now match REAPER's, " \
            "the known gap is fixed: assert a match here instead."
