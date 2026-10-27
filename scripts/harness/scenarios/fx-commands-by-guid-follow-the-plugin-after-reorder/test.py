"""An FX's index changes when the chain is reordered (by the user in
REAPER, or by another phone); its GUID doesn't. Preset and bypass commands
that name the FX by GUID must reach the plugin the user tapped, not
whichever plugin now sits at its old index."""
import time

from reamo_client import Client, reaper

STATE = """
local t = reaper.GetTrack(0, 0)
local out = {}
for i = 0, reaper.TrackFX_GetCount(t) - 1 do
  local _, name = reaper.TrackFX_GetFXName(t, i, '')
  local preset = reaper.TrackFX_GetPresetIndex(t, i)
  out[#out + 1] = string.format('%s|%d|%s', name, preset, tostring(reaper.TrackFX_GetEnabled(t, i)))
end
return table.concat(out, ';')
"""


def state():
    return [tuple(fx.split("|")) for fx in reaper(STATE).split(";")]


def settle(want, timeout=2.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        got = state()
        if want(got):
            return got
        time.sleep(0.05)
    return state()


track_guid = reaper("return reaper.GetTrackGUID(reaper.GetTrack(0, 0))")
eq_guid = reaper("return reaper.TrackFX_GetFXGUID(reaper.GetTrack(0, 0), 1)")
with Client() as c:
    c.wait_event("transport")
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    # The user opened the FX list with ReaEQ second; then ReaEQ is dragged
    # to the top of the chain in REAPER.
    reaper("local t = reaper.GetTrack(0, 0); reaper.TrackFX_CopyToTrack(t, 1, t, 0, true)")
    before = state()
    assert before[0][0].startswith("VST: ReaEQ") or "ReaEQ" in before[0][0], before

    r = c.command("trackFx/presetSet", trackGuid=track_guid, fxGuid=eq_guid, presetIdx=3)
    assert r["success"], r
    got = settle(lambda s: s[0][1] == "3")
    assert got[0][1] == "3", f"ReaEQ (now first) should be on preset 3: {got}"
    assert got[1][1] == before[1][1], f"the plugin at ReaEQ's old index changed preset: {got}"

    c.fire("trackFx/presetNext", trackGuid=track_guid, fxGuid=eq_guid)
    got = settle(lambda s: s[0][1] == "4")
    assert got[0][1] == "4", f"presetNext missed ReaEQ: {got}"
    c.fire("trackFx/presetPrev", trackGuid=track_guid, fxGuid=eq_guid)
    got = settle(lambda s: s[0][1] == "3")
    assert got[0][1] == "3", f"presetPrev missed ReaEQ: {got}"

    r = c.command("trackFx/setEnabled", trackGuid=track_guid, fxGuid=eq_guid, enabled=0)
    assert r["success"], r
    got = state()
    assert got[0][2] == "false" and got[1][2] == "true", f"bypass should hit ReaEQ only: {got}"

    gone = "{00000000-0000-0000-0000-000000000000}"
    for cmd, extra in (("trackFx/presetNext", {}), ("trackFx/presetSet", {"presetIdx": 1}),
                       ("trackFx/setEnabled", {"enabled": 1})):
        r = c.command(cmd, trackGuid=track_guid, fxGuid=gone, **extra)
        assert not r["success"] and r["error"]["code"] == "NOT_FOUND", f"{cmd} with a gone fxGuid: {r}"
    assert state() == got, "a command naming a gone FX changed the chain"
print("ok: preset and bypass commands by fxGuid follow the plugin through a reorder")
