"""Edits in REAPER that swap a take's source or change its rate refresh a phone's waveform.

While a phone watches, the user reverses a take, gives an item a section
(trimming the item to it), doubles a take's playrate (likewise), and
switches an item's active take. Each one changes what REAmo checks for
peaks changes (the take's source, playrate, the item's length or active
take), so a new peaks frame arrives with tiles matching REAPER's peaks, and
a phone that connects afterwards gets the same. (A slip edit is
peaks-follow-slip-edit.)
"""
from reamo_client import Client, reaper
import peaks_check as pk

EDITS = {
    "reverse": "harness.reverse_take(it)",
    "section": 'harness.section(it, 2, 3); reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 3)',
    "playrate": 'reaper.SetMediaItemTakeInfo_Value(reaper.GetActiveTake(it), "D_PLAYRATE", 2); '
                'reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 4)',
    "active take": "reaper.SetActiveTake(reaper.GetTake(it, 1))",
}
AFTER = {"reverse": pk.steps(0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1),
         "section": pk.steps(0.3, 0.4, 0.5),
         "playrate": pk.steps(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, per=1),
         "active take": pk.steps(0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1)}

with Client() as c:
    c.wait_event("items")
    pk.subscribe_all(c)
    pk.drain_until_quiet(c)
    bad, evidence = [], {}
    for name, edit in EDITS.items():
        ti = pk.track_index(name)
        n = len(c.binary)
        reaper(f"local it = reaper.GetTrackMediaItem(reaper.GetTrack(0, {ti}), 0); {edit}; reaper.UpdateArrange()")
        tiles = pk.wait_tiles(c, n)
        profiles, b = pk.compare(tiles, [name])
        evidence[name] = profiles[name]
        want = profiles[name][1]["max"][0]
        assert pk.near(want, AFTER[name]), f"REAPER's peaks after the {name} edit: {pk.fmt(want)}"
        bad += [f"after the {name} edit, the watching phone's " + line for line in b]

    with Client() as late:
        late.wait_event("items")
        profiles, b = pk.compare(pk.subscribe_all(late), list(EDITS))
        bad += ["a phone connecting afterwards: " + line for line in b]
    pk.save("profiles", evidence)
    pk.screenshot_arrange("reaper-arrange")
    assert not bad, "\n".join(bad)
