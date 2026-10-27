"""Every plugin the Add-FX browser lists can be added with the ident it was given.

The browser (FxBrowserModal) sends trackFx/add with fxName = the ident that
fxPlugin/getList returned. Each add must succeed, land at the end of the chain,
and report the index and GUID REAPER actually gave it.
"""
import time
from reamo_client import Client, reaper


def wait_guid_cache(c, guid, t0):
    """Track-GUID commands answer NOT_FOUND until the extension's GUID cache
    has seen the fixture's tracks; wait for that (a probe that fails with
    FX_NOT_FOUND once the track resolves)."""
    while True:
        r = c.command("trackFx/delete", trackGuid=guid, fxIndex=9999)
        if r["error"]["code"] != "NOT_FOUND":
            print(f"track GUID resolvable {time.time() - t0:.2f} s after connect")
            return
        assert time.time() - t0 < 5, "track GUID never became resolvable"
        time.sleep(0.05)

with Client(timeout=10) as c:
    t0 = time.time()
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    wait_guid_cache(c, g, t0)
    plugins = c.command("fxPlugin/getList")["payload"]
    print(f"{len(plugins)} plugins listed")
    kinds = {}
    problems = []
    for name, ident in plugins:
        kind = name.split(":")[0] if ":" in name else name
        r = c.command("trackFx/add", trackGuid=g, fxName=ident)
        n, guid0 = reaper("""
            local t = reaper.GetTrack(0, 0)
            return reaper.TrackFX_GetCount(t), reaper.TrackFX_GetFXGUID(t, 0) or ''
        """)
        ok = r["success"] and n == 1 and r["payload"]["fxIndex"] == 0 and r["payload"]["fxGuid"] == guid0
        kinds.setdefault(kind, [0, 0])[0 if ok else 1] += 1
        if not ok:
            problems.append(f"{name!r} ident={ident!r}: response={r.get('payload') or r.get('error')} chain={n}")
        reaper("local t = reaper.GetTrack(0, 0); while reaper.TrackFX_GetCount(t) > 0 do reaper.TrackFX_Delete(t, 0) end")
    print("ok/failed by kind:", kinds)
    for p in problems[:25]:
        print("  ", p)
    assert not problems, f"{len(problems)} of {len(plugins)} listed plugins could not be added"
