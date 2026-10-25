"""Metronome, count-in and smooth-seek settings from the phone are REAPER's settings.

Each toggle/set must change what REAPER itself reports (toggle states,
projmetrov1/projmetroen, smoothseek/smoothseekmeas config vars) and the
project event must follow; nonsense values must not corrupt REAPER's prefs.
"""
import time

from reamo_client import Client, reaper, skip


def cfg(name):
    return reaper(f"return harness.config('{name}')")


# REAPER 6.0 can't read these settings from a script, so nothing can check them.
if cfg("projmetrov1") is None:
    skip(f"REAPER {reaper('return reaper.GetAppVersion()')} can't read its metronome settings from a script")


def project_settles(c, pred):
    deadline = time.time() + 2
    while time.time() < deadline:
        c.drain(0.2)
        p = c.latest_event("project")["payload"]
        if pred(p):
            return p
    return c.latest_event("project")["payload"]


with Client() as c:
    c.wait_event("project")
    problems = []

    c.fire("metronome/toggle")
    p = project_settles(c, lambda p: p["metronome"]["enabled"])
    on = reaper("return reaper.GetToggleCommandState(40364)")
    print(f"  metronome/toggle: REAPER {on}, shown {p['metronome']}")
    if on != 1 or not p["metronome"]["enabled"]:
        problems.append(f"metronome/toggle: REAPER toggle {on}, event {p['metronome']}")

    for params, want_lin in (({"volumeDb": -6}, 10 ** (-6 / 20)), ({"volumeDb": 40}, 4.0),
                             ({"volume": -3}, 0.0), ({"volumeDb": -200}, 0.0), ({"volume": 0.5}, 0.5)):
        r = c.command("metronome/setVolume", **params)
        got = float(cfg("projmetrov1"))
        g = c.command("metronome/getVolume")
        print(f"  setVolume {params}: {r.get('error') or 'ok'}; REAPER projmetrov1={got:.4f}; getVolume {g.get('payload')}")
        if abs(got - want_lin) > 1e-3:
            problems.append(f"setVolume {params}: REAPER volume {got}, want {want_lin:.4f}")
        if not g["success"] or abs(g["payload"]["volume"] - got) > 1e-4:
            problems.append(f"getVolume after {params}: {g}")

    before = int(cfg("projmetroen"))
    c.fire("countIn/togglePlayback")
    c.fire("countIn/toggleRecord")
    p = project_settles(c, lambda p: p["countIn"] == {"playback": not (before & 8), "recording": not (before & 16)})
    after = int(cfg("projmetroen"))
    print(f"  count-in toggles: projmetroen {before} -> {after}; shown {p['countIn']}")
    if after != before ^ 24:
        problems.append(f"count-in toggles: projmetroen {before} -> {after}, want {before ^ 24}")
    if p["countIn"] != {"playback": bool(after & 8), "recording": bool(after & 16)}:
        problems.append(f"count-in event {p['countIn']} vs REAPER projmetroen {after}")

    r = c.command("preferences/setSeekSettings", enabled=1, measures=4, mode=1)
    g = c.command("preferences/getSeekSettings")
    ss, meas = int(cfg("smoothseek")), int(cfg("smoothseekmeas"))
    print(f"  setSeekSettings 1/4/marker: {r.get('error') or 'ok'}; REAPER smoothseek={ss} smoothseekmeas={meas}; get {g['payload']}")
    if (ss & 3, meas) != (3, 4) or g["payload"] != {"enabled": True, "measures": 4, "mode": "marker"}:
        problems.append(f"setSeekSettings 1/4/marker: REAPER smoothseek={ss} meas={meas}, get {g['payload']}")
    for bad in ({"measures": -3}, {"measures": 0}, {"measures": 100000}):
        r = c.command("preferences/setSeekSettings", **bad)
        meas = int(cfg("smoothseekmeas"))
        print(f"  setSeekSettings {bad}: {r.get('error') or 'ok'}; REAPER smoothseekmeas={meas}")
        if r["success"] and meas == list(bad.values())[0]:
            problems.append(f"setSeekSettings {bad} accepted and wrote smoothseekmeas={meas} into REAPER's prefs")
    assert not problems, "\n".join(problems)
