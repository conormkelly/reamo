"""Opening and closing track tuners leaves REAPER's project exactly as it
was: no undo point, not dirty, no plugin anywhere (RV1-165).

A tuner that adds a plugin to the track's input FX and deletes it again
leaves two undo points per open and close ("Add FX", "Remove FX"), a
dirty project (REAPER asking to save after only tuning), the plugin saved
in the .RPP if saved meanwhile, and Ctrl+Z bringing it back as an orphan.
Against such a tuner, every check here fails.

The fixture is a saved, clean project on JACK. A known undo point goes on
top ("PROBE MARK", a rename in its own undo block), and the project is
saved. Then three phones tune for 30 rounds, each with a pluck on both
inputs: A on Bass, B on Guitar, C on Keys (the stereo pair), with
setParam calls and every way of leaving (unsubscribing, switching track,
the connection dropping). Checked while they tune, and after:
- the top of the undo history is still PROBE MARK, with nothing to redo;
- GetProjectStateChangeCount hasn't moved and the project isn't dirty;
- no track gained an FX in either chain, nor the monitoring chain, and
  Guitar's own input FX is still the only one, first.
And the tuners did tune: each phone read its pluck.
"""
import time

from reamo_client import Client, reaper, skip_unless_linux

skip_unless_linux("REAPER's inputs come from the container's JACK server")

from jack_feeder import Feeder  # noqa: E402  after the skip: Linux only
from tuner_phone import Phone, watch  # noqa: E402

ROUNDS = 30

SNAPSHOT = """
local out = {
  undo = reaper.Undo_CanUndo2(0) or "",
  redo = reaper.Undo_CanRedo2(0) or "",
  scc = reaper.GetProjectStateChangeCount(0),
  dirty = reaper.IsProjectDirty(0),
  monitoring = reaper.TrackFX_GetRecCount(reaper.GetMasterTrack(0)),
  master = reaper.TrackFX_GetCount(reaper.GetMasterTrack(0)),
  fx = {},
}
for i = 0, reaper.CountTracks(0) - 1 do
  local t = reaper.GetTrack(0, i)
  local names = {}
  for k = 0, reaper.TrackFX_GetRecCount(t) - 1 do
    local _, n = reaper.TrackFX_GetFXName(t, 0x1000000 + k, "")
    names[#names + 1] = n
  end
  out.fx[#out.fx + 1] = reaper.TrackFX_GetCount(t) .. " / " .. table.concat(names, ", ")
end
return out
"""

reaper("""
reaper.Undo_BeginBlock2(0)
reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(0, 0), "P_NAME", "Bass (DI)", true)
reaper.Undo_EndBlock2(0, "PROBE MARK", -1)
reaper.Main_SaveProject(0, false)
""")
before = reaper(SNAPSHOT)
print("before:", before)
assert before["undo"] == "PROBE MARK" and before["dirty"] == 0, before

problems = []


def check(when):
    now = reaper(SNAPSHOT)
    if now != before:
        diff = {k: (before[k], now[k]) for k in before if before[k] != now[k]}
        problems.append(f"{when}: {diff}")
        return False
    return True


read = {"A": 0, "B": 0, "C": 0}
with Feeder() as f:
    f.wait_connected()
    with Client() as a, Client() as b:
        skel = a.wait_event("trackSkeleton")["payload"]["tracks"]
        bass, gtr, keys = skel[1]["g"], skel[2]["g"], skel[3]["g"]
        time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
        pa, pb = Phone(a, "A"), Phone(b, "B")
        for k in range(ROUNDS):
            c = Client()
            pc = Phone(c, "C")
            for phone, guid in ((pa, bass), (pb, gtr), (pc, keys)):
                r = phone.subscribe(guid)
                assert r["success"], (phone.name, r)
                phone.mark()
            b.command("tuner/setParam", trackGuid=gtr, param="reference", value=441.0 + k % 3)
            c.command("tuner/setParam", trackGuid=keys, param="threshold", value=-80.0)
            f.pluck(0, 82.41, 0.8, decay=1.0)
            f.pluck(1, 220.0, 0.8, decay=1.0)
            watch([pa, pb, pc], 0.5)
            for phone in (pa, pb, pc):
                read[phone.name] += bool(phone.pitched())
            if k % 10 == 0:
                check(f"round {k + 1}, while tuning")
            # Every way of leaving: A unsubscribes, B switches to Bass (so
            # leaves Guitar) then unsubscribes, C's connection drops.
            a.command("tuner/unsubscribe")
            pb.subscribe(bass)
            b.command("tuner/unsubscribe")
            if k % 2:
                c.close()
            else:
                c.command("tuner/unsubscribe")
                c.close()
        time.sleep(0.5)
        status = a.command("audio/status")["payload"]
        print("after:", status["inputTaps"], "taps, hook users", status["hookUsers"])
        if status["inputTaps"] != 0 or status["hookUsers"]["inputs"]:
            problems.append(f"input taps left after every phone left: {status['inputTaps']}, {status['hookUsers']}")

after = reaper(SNAPSHOT)
print("after:", after)
check(f"after {ROUNDS} rounds")
print("rounds in which each phone read its pluck:", read)
for name, n in read.items():
    if n < ROUNDS * 0.9:
        problems.append(f"phone {name} read its pluck in only {n} of {ROUNDS} rounds")

assert not problems, "\n".join(problems)
print(f"ok: {ROUNDS} rounds of three phones tuning left no undo point, no dirt and no plugin")
