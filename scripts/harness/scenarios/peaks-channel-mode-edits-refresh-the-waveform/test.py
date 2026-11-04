"""A channel mode change in REAPER refreshes a phone's waveform, lane count included.

While a phone watches, the user changes takes' channel modes: from normal
to mono (two waveforms to one), from mono to normal (one to two), from mono
left to mono right (one waveform, another channel), and from normal to
reverse stereo (the channels swap). Each change gives the take a new epoch,
so a peaks frame arrives with its tiles under that epoch, matching REAPER's
peaks and with the channel count REAPER draws; a phone that connects
afterwards gets the same, not tiles cached from before the change.
(peaks-channel-modes-match-reaper has the rule for each mode.)
"""
from reamo_client import Client, reaper
import peaks_check as pk

STAIRS = pk.steps(0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8)
RIGHT = [0.25] * 16

# name: (new I_CHANMODE, channels REAPER draws before and after, REAPER's
# peaks per channel after)
EDITS = {
    "normal to mono (left)": (3, 2, 1, [STAIRS]),
    "mono (downmix) to normal": (0, 1, 2, [STAIRS, RIGHT]),
    "mono (left) to mono (right)": (4, 1, 1, [RIGHT]),
    "normal to reverse stereo": (1, 2, 2, [RIGHT, STAIRS]),
}


def channels_sent(tiles, guid):
    return sorted({t["ch"] for t in tiles if t["guid"] == guid})


with Client() as c:
    c.wait_event("items")
    first = pk.subscribe_all(c)
    pk.drain_until_quiet(c)
    bad, evidence = [], {}
    for name, (_, before, _, _) in EDITS.items():
        profiles, b = pk.compare(first, [name], before)
        bad += [f"before the {name} edit: " + line for line in b]
        sent = channels_sent(first, profiles[name][1]["guid"])
        if sent != [before]:
            bad.append(f"before the {name} edit, the phone got {sent} channels, not {before}")

    for name, (mode, _, after, levels) in EDITS.items():
        ti = pk.track_index(name)
        n = len(c.binary)
        reaper(f"""local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(reaper.GetTrack(0, {ti}), 0))
reaper.SetMediaItemTakeInfo_Value(tk, "I_CHANMODE", {mode}); reaper.UpdateArrange()""")
        try:
            tiles = pk.wait_tiles(c, n)
        except AssertionError as e:
            bad.append(f"after the {name} edit: {e}")
            continue
        profiles, b = pk.compare(tiles, [name], after)
        evidence[name] = profiles[name]
        got, want = profiles[name]
        for ch, level in enumerate(levels):
            assert pk.near(want["max"][ch], level), f"REAPER's peaks after the {name} edit, " \
                f"channel {ch}: {pk.fmt(want['max'][ch])}"
        bad += [f"after the {name} edit, the watching phone's " + line for line in b]
        sent = channels_sent(tiles, want["guid"])
        if sent != [after]:
            bad.append(f"after the {name} edit, the watching phone got {sent} channels, not {after}")
        epochs = {t["epoch"] for t in pk.take_tiles(first, want["guid"])}
        if epochs & {t["epoch"] for t in tiles if t["guid"] == want["guid"]}:
            bad.append(f"after the {name} edit, the watching phone got tiles under the epoch from before it")

    with Client() as late:
        late.wait_event("items")
        fresh = pk.subscribe_all(late)
        for name, (_, _, after, _) in EDITS.items():
            profiles, b = pk.compare(fresh, [name], after)
            bad += ["a phone connecting afterwards: " + line for line in b]
            sent = channels_sent(fresh, profiles[name][1]["guid"])
            if sent != [after]:
                bad.append(f"a phone connecting afterwards got {sent} channels for {name}, not {after}")
    pk.save("profiles", evidence)
    pk.screenshot_arrange("reaper-arrange")
    assert not bad, "\n".join(bad)
