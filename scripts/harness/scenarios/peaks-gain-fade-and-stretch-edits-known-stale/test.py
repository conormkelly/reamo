"""Known gap (RV1-151): edits in REAPER to a take's gain, fades, stretch markers, looping or channel mode leave phones showing the old waveform.

REAPER redraws the waveform at once for each of these edits (its peaks, from
GetMediaItemTake_Peaks, change). REAmo looks for peaks changes only in
the take's source, channel count, start offset and playrate, and the
item's position, length and active take. So after any of these edits:

- no peaks frame arrives;
- REAmo's tile cache, shared by every phone and keyed by take, an epoch
  (the take's source, channel count, start offset and playrate), LOD and
  tile, still holds the old tiles: a frame sent for another reason (here, a slip
  edit on another track), and a phone that connects afterwards, get the
  waveform from before the edit.

This scenario pins that, after checking each edit did change REAPER's
peaks. When REAmo refreshes after one of these edits, its assertion fails:
move that edit to peaks-source-and-rate-edits-refresh-the-waveform.
"""
from reamo_client import Client, reaper
import peaks_check as pk

ENVELOPE = """
reaper.SelectAllMediaItems(0, false); reaper.SetMediaItemSelected(it, true)
reaper.Main_OnCommand(40693, 0); reaper.SelectAllMediaItems(0, false)
local env = reaper.GetTakeEnvelopeByName(tk, "Volume")
local m = reaper.GetEnvelopeScalingMode(env)
reaper.DeleteEnvelopePointRange(env, -1, 100)
reaper.InsertEnvelopePoint(env, 0, reaper.ScaleToEnvelopeMode(m, 0), 0, 0, false, true)
reaper.InsertEnvelopePoint(env, 8, reaper.ScaleToEnvelopeMode(m, 1), 0, 0, false, true)
reaper.Envelope_SortPoints(env)
"""
EDITS = {
    "item volume": 'reaper.SetMediaItemInfo_Value(it, "D_VOL", 0.5)',
    "take volume": 'reaper.SetMediaItemTakeInfo_Value(tk, "D_VOL", 0.5)',
    "fade in": 'reaper.SetMediaItemInfo_Value(it, "D_FADEINLEN", 3)',
    "stretch markers": "reaper.SetTakeStretchMarker(tk, -1, 0, 0); reaper.SetTakeStretchMarker(tk, -1, 2, 4); "
                       "reaper.SetTakeStretchMarker(tk, -1, 8, 8)",
    "take volume envelope": ENVELOPE,
    "loop source": 'reaper.SetMediaItemInfo_Value(it, "B_LOOPSRC", 0)',
    "take pan": 'reaper.SetMediaItemTakeInfo_Value(tk, "D_PAN", -1)',
    "channel mode": 'reaper.SetMediaItemTakeInfo_Value(tk, "I_CHANMODE", 3)',
}
STEREO = {"take pan", "channel mode"}


def edit(name, lua):
    ti = pk.track_index(name)
    reaper(f"local it = reaper.GetTrackMediaItem(reaper.GetTrack(0, {ti}), 0); local tk = reaper.GetActiveTake(it); "
           f"{lua}; reaper.UpdateArrange()")


def channels(name):
    return 2 if name in STEREO else 1


with Client() as c:
    c.wait_event("items")
    first = pk.subscribe_all(c)
    pk.drain_until_quiet(c)
    before = {name: pk.compare(first, [name], channels(name)) for name in EDITS}
    for name, (profiles, b) in before.items():
        assert not b, "\n".join(b)  # REAmo matched REAPER before the edit

    stale = {}
    for name, lua in EDITS.items():
        n = len(c.binary)
        edit(name, lua)
        c.drain(1.5)
        reamo_before, reaper_before = before[name][0][name]
        reaper_after = pk.reaper_profile(pk.track_index(name))
        # The edit changed what REAPER draws, or this checks nothing.
        assert pk.mismatches(name, reaper_after, reaper_before, channels(name)), \
            f"the {name} edit didn't change REAPER's peaks"
        mine = pk.take_tiles(pk.tiles_since(c, n), reaper_after["guid"])
        stale[name] = {"reamo": reamo_before, "reaper_before": reaper_before, "reaper_after": reaper_after}
        # Known gap: no new tiles for the edited take.
        assert not mine, f"REAmo sent new tiles after the {name} edit. If they match REAPER's, the known gap " \
                         "is fixed for it: move it to peaks-source-and-rate-edits-refresh-the-waveform."

    # A slip edit on another track is seen: a frame arrives, so the waits
    # above were long enough. It re-sends the edited takes' old tiles.
    n = len(c.binary)
    edit("slip (control)", 'reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", 1); '
                           'reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 7)')
    resent = pk.wait_tiles(c, n)
    _, b = pk.compare(resent, ["slip (control)"])
    assert not b, "\n".join(b)

    with Client() as late:
        late.wait_event("items")
        fresh = pk.subscribe_all(late)
    for label, tiles in (("re-sent after the control edit", resent), ("sent to a phone connecting afterwards", fresh)):
        for name in EDITS:
            mine = pk.take_tiles(tiles, stale[name]["reaper_after"]["guid"])
            assert mine, f"{name}: no tiles {label}"
            got = pk.reamo_profile(mine, stale[name]["reaper_after"]["length"])
            assert not pk.mismatches(name, got, stale[name]["reaper_before"], channels(name)), \
                f"{name}: the waveform {label} is no longer the one from before the edit:\n" + \
                "\n".join(pk.mismatches(name, got, stale[name]["reaper_before"], channels(name)))
            assert pk.mismatches(name, got, stale[name]["reaper_after"], channels(name)), \
                f"{name}: the waveform {label} matches REAPER's after the edit, though no tiles were sent for it"
    pk.save("profiles", stale)
    pk.save("reamo-tiles-after-edits", fresh)
    pk.screenshot_arrange("reaper-arrange")
