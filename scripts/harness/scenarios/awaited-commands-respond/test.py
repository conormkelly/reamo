"""Every command the web UI awaits gets a response within its 5 s timeout."""
import time
from reamo_client import Client

FRONTEND_TIMEOUT = 5.0

with Client(timeout=FRONTEND_TIMEOUT) as c:
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    track_guid = skel[1]["g"]
    # The UI learns FX GUIDs from the trackFxChain event, as here.
    assert c.command("trackFx/subscribe", trackGuid=track_guid)["success"]
    chain = c.wait_event("trackFxChain")["payload"]
    fx = chain.get("fx", [])
    print("fx chain:", [{k: v for k, v in f.items() if k in ("name", "n", "guid", "g", "fxGuid")} for f in fx])
    fx_guid = next(f.get(k) for f in fx for k in ("fxGuid", "guid", "g") if f.get(k))

    awaited = [
        ("tempo/barsToTime", {"bar": 3, "beat": 2, "ticks": 50}),
        ("tempo/timeToBeats", {"time": 6.5}),
        ("trackFx/getParams", {"trackGuid": track_guid, "fxGuid": fx_guid}),
        ("projectNotes/subscribe", {}),
        ("projectNotes/get", {}),
        ("projectNotes/set", {"notes": "Edited from the phone\nline 2"}),
        ("input/enumerateAudio", {}),
        ("input/enumerateMidi", {}),
        ("hw/listOutputs", {}),
        ("hw/add", {"trackIdx": 1, "destChannel": 0}),
        ("fxPlugin/getList", {}),
        ("debug/memoryStats", {}),
        ("extstate/projSet", {"extname": "Reamo", "key": "CustomBanks", "value": "[]"}),
        ("extstate/projGet", {"extname": "Reamo", "key": "CustomBanks"}),
        ("audio/startStream", {}),
        ("audio/stopStream", {}),
        ("track/setInput", {"trackIdx": 1, "inputType": "audio", "channel": 0}),
    ]
    problems = []
    for cmd, params in awaited:
        t0 = time.time()
        try:
            r = c.command(cmd, **params)
        except TimeoutError:
            problems.append(f"{cmd}: no response within {FRONTEND_TIMEOUT:.0f} s")
            continue
        ms = (time.time() - t0) * 1000
        status = "ok" if r["success"] else f"error {r.get('error')}"
        print(f"  {cmd:24s} {status:40.40s} {ms:6.1f} ms")
        if not r["success"]:
            problems.append(f"{cmd}: {r.get('error')}")
    assert not problems, "\n".join(problems)
