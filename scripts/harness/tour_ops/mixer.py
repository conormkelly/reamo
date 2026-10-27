"""Mixer: volume, pan, mute, solo, arm, monitoring, FX bypass, selection,
name and colour of tracks.

Each op picks its track by role (any track, an unmuted one, one with FX),
preferring the band session's track for that flow, and puts back what it
changed so the next op sees the project as it was."""
import time

from tour import approx, op


@op("track/setVolume by index and by GUID", "track/setVolume")
def _(t):
    g, tr = t.track_for("Bass DI", role="to set the volume of")
    master = t.d["tracks"]["master"]["vol"]
    t.ok("track/setVolume", trackIdx=tr["pos"], volume=0.5)
    t.expect({f"tracks.{g}.vol": approx(0.5, 1e-4)})
    t.digest()
    t.ok("track/setVolume", trackGuid=g, volume=1.25)
    t.expect({f"tracks.{g}.vol": approx(1.25, 1e-4)})
    t.digest()
    t.ok("track/setVolume", trackIdx=0, volume=0.8)  # master
    t.expect({"tracks.master.vol": approx(0.8, 1e-4)})
    t.ok("track/setVolume", trackGuid=g, volume=tr["vol"])
    t.ok("track/setVolume", trackIdx=0, volume=master)
    t._wait_equal(t.op_start, "setting the volumes back did not restore the project")


@op("track/setPan", "track/setPan")
def _(t):
    g, tr = t.track_for("Guitar", lambda g, tr: abs(tr["pan"] + 0.4) > 1e-3, role="to pan")
    t.ok("track/setPan", trackGuid=g, pan=-0.4)
    t.expect({f"tracks.{g}.pan": approx(-0.4)})
    t.ok("track/setPan", trackGuid=g, pan=tr["pan"])
    t._wait_equal(t.op_start, "setting the pan back did not restore the project")


@op("fader drag: gesture + 30 setVolume = one undo step", "gesture/start", "gesture/end")
def _(t):
    g, tr = t.track_for("Kick", lambda g, tr: abs(tr["vol"] - 0.42) > 1e-3, role="to drag the fader of")
    t.ok("gesture/start", controlType="volume", trackGuid=g)
    for i in range(30):
        t.c.fire("track/setVolume", trackGuid=g, volume=1.0 - i * 0.02)
        time.sleep(0.01)
    t.ok("gesture/end", controlType="volume", trackGuid=g)
    t.expect({f"tracks.{g}.vol": approx(0.42, 1e-3)})
    t.check_undo()
    t.send("undo/do", awaited=True)
    t._wait_equal(t.op_start, "undoing the fader drag did not restore the project")


@op("track/setMute explicit and toggle", "track/setMute")
def _(t):
    g, tr = t.track_for("Snare", lambda g, tr: not tr["mute"], role="that is unmuted")
    t.ok("track/setMute", trackIdx=tr["pos"], mute=1)
    t.expect({f"tracks.{g}.mute": 1})
    t.digest()
    t.ok("track/setMute", trackGuid=g)  # toggle
    t.expect({f"tracks.{g}.mute": 0})


@op("track/setSolo + setSoloExclusive", "track/setSolo", "track/setSoloExclusive")
def _(t):
    unsoloed = lambda g, tr: not tr["solo"]  # noqa: E731
    g1, _ = t.track_for("Guitar", unsoloed, role="that is not soloed")
    g2, tr2 = t.track_for("Keys", unsoloed, role="besides the first that is not soloed", exclude={g1})
    t.ok("track/setSolo", trackGuid=g1, solo=1)
    t.expect({f"tracks.{g1}.solo": lambda v: v > 0})
    t.digest()
    t.ok("track/setSoloExclusive", trackIdx=tr2["pos"])
    t.expect({f"tracks.{g1}.solo": 0, f"tracks.{g2}.solo": lambda v: v > 0})
    t.digest()
    t.ok("track/setSolo", trackGuid=g2, solo=0)
    t.expect({f"tracks.{g2}.solo": 0})


@op("track/setRecArm + setRecMon", "track/setRecArm", "track/setRecMon")
def _(t):
    g, tr = t.track_for("Guitar", lambda g, tr: not tr["arm"] and tr["mon"] != 2, role="that is not armed")
    t.ok("track/setRecArm", trackGuid=g, arm=1)
    t.expect({f"tracks.{g}.arm": 1})
    t.digest()
    t.ok("track/setRecMon", trackGuid=g, mon=2)
    t.expect({f"tracks.{g}.mon": 2})
    t.digest()
    t.ok("track/setRecArm", trackGuid=g, arm=0)
    t.expect({f"tracks.{g}.arm": 0})
    t.ok("track/setRecMon", trackGuid=g, mon=int(tr["mon"]))
    t._wait_equal(t.op_start, "setting the monitoring back did not restore the project")


@op("track/setFxEnabled", "track/setFxEnabled")
def _(t):
    g, tr = t.track_for("Drums", lambda g, tr: tr["fx"] and tr["fxen"], role="with FX switched on")
    t.ok("track/setFxEnabled", trackGuid=g, enabled=0)
    t.expect({f"tracks.{g}.fxen": 0})
    t.digest()
    t.ok("track/setFxEnabled", trackGuid=g)
    t.expect({f"tracks.{g}.fxen": 1})


@op("track/setSelected + unselectAll", "track/setSelected", "track/unselectAll")
def _(t):
    g, tr = t.track_for("BVs", lambda g, tr: not tr["sel"], role="that is not selected")
    was = [x for x, xt in t.tracks() if xt["sel"]]
    t.ok("track/setSelected", trackGuid=g, selected=1)
    t.expect({f"tracks.{g}.sel": 1})
    t.digest()
    t.ok("track/unselectAll")
    t.expect({"tracks.*.sel": 0})
    for x in was:
        t.ok("track/setSelected", trackGuid=x, selected=1)
    t._wait_equal(t.op_start, "selecting the user's tracks again did not restore the project")


@op("track/rename", "track/rename")
def _(t):
    name = "Backing Vocals – Ünïcødé 🎤"
    g, tr = t.track_for("BVs", lambda g, tr: tr["name"] != name, role="to rename")
    t.ok("track/rename", trackIdx=tr["pos"], name=name)
    t.expect({f"tracks.{g}.name": name})
    t.check_undo()
    t.send("undo/do", awaited=True)
    t._wait_equal(t.op_start, "undoing the rename did not restore the project")


@op("track/setColor + reset", "track/setColor")
def _(t):
    blue = 0x1000000 | 0x3366CC
    g, tr = t.track_for("Bass DI", lambda g, tr: tr["color"] != blue, role="to colour")
    t.ok("track/setColor", trackGuid=g, color=blue)
    t.expect({f"tracks.{g}.color": blue})
    t.digest()
    t.ok("track/setColor", trackGuid=g, color=0)
    t.expect({f"tracks.{g}.color": 0})
    # Two Ctrl+Z put back the colour REAPER had, including a value without
    # REAPER's custom flag (the theme colour, as 0 is), which no phone
    # command sends.
    for _ in range(2):
        t.send("undo/do", awaited=True)
    t._wait_equal(t.op_start, "undoing the colour changes did not restore the project")
