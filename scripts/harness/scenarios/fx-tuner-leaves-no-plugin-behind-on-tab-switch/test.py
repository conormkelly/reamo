"""The tuner's plugin goes on the tuned track's input FX and must go when
the tuner stops, even if the user has switched to another project tab in
the meantime: left behind, it is saved into a project that never asked
for it, and shows as a missing plugin wherever REAmo isn't installed."""
import time

from reamo_client import Client, reaper

# The first tab's tuned track, by project pointer: GetTrack(0, ...) is the
# current tab.
TUNERS_IN_FIRST_TAB = "return reaper.TrackFX_GetRecCount(reaper.GetTrack(first_tab, 0))"


def tuners_in_first_tab_settle(want, timeout=3.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        n = reaper(TUNERS_IN_FIRST_TAB)
        if n == want:
            return n
        time.sleep(0.1)
    return reaper(TUNERS_IN_FIRST_TAB)


for how in ("phone closes the tuner", "tuner loses its track"):
    with Client() as c:
        bass = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
        time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
        reaper("first_tab = reaper.EnumProjects(-1)")
        r = c.command("tuner/subscribe", trackGuid=bass)
        assert r["success"], r
        assert reaper(TUNERS_IN_FIRST_TAB) == 1

        reaper("reaper.Main_OnCommand(40859, 0)")  # New project tab
        if how == "phone closes the tuner":
            c.command("tuner/unsubscribe")
        n = tuners_in_first_tab_settle(0)
        print(f"{how}: {n} tuner plugin(s) left in the first tab")
        assert n == 0, f"{how}: the tuner plugin was left in the first project tab"

        # Back to the first tab for the next round.
        reaper("reaper.Main_OnCommand(40860, 0); reaper.SelectProjectInstance(first_tab)")
        assert reaper("return reaper.EnumProjects(-1) == first_tab") is True
print("ok: the tuner removes its plugin from the project it put it in")
