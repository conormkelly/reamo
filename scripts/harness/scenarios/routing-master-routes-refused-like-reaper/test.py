"""REAPER has no track send from or to the master track (tracks reach the
master through their master send), and no items on it: CreateTrackSend
declines such a route while still returning an index, and an item can't be
moved there. A phone asking for one must be told it failed, not told it
worked while nothing changed."""
from reamo_client import Client, reaper

STATE = '''
local m = reaper.GetMasterTrack(0)
local t = reaper.GetTrack(0, 0)
local it = reaper.GetTrackMediaItem(t, 0)
return string.format("master sends=%d recvs=%d items=%d | Vox sends=%d recvs=%d items=%d pos=%.3f",
  reaper.GetTrackNumSends(m, 0), reaper.GetTrackNumSends(m, -1), reaper.CountTrackMediaItems(m),
  reaper.GetTrackNumSends(t, 0), reaper.GetTrackNumSends(t, -1), reaper.CountTrackMediaItems(t),
  reaper.GetMediaItemInfo_Value(it, "D_POSITION"))
'''
vox = reaper("return reaper.GetTrackGUID(reaper.GetTrack(0, 0))")
bus = reaper("return reaper.GetTrackGUID(reaper.GetTrack(0, 1))")
item = reaper('return select(2, reaper.GetSetMediaItemInfo_String(reaper.GetTrackMediaItem(reaper.GetTrack(0, 0), 0), "GUID", "", false))')
before = reaper(STATE)
with Client() as c:
    c.wait_event("transport")
    for cmd, params in (("send/add", {"trackGuid": "master", "destTrackGuid": vox}),
                        ("receive/add", {"trackGuid": "master", "srcTrackGuid": vox}),
                        ("item/moveByGuid", {"guid": item, "destTrackGuid": "master", "position": 5.0})):
        r = c.command(cmd, **params)
        assert not r["success"], f"{cmd} {params} reported success: {r}"
        print(f"{cmd}: {r['error']}")
        assert reaper(STATE) == before, f"{cmd} changed the project: {reaper(STATE)}"

    # A real send still works, and reports REAPER's index.
    r = c.command("send/add", trackGuid=vox, destTrackGuid=bus)
    assert r["success"] and r["payload"]["sendIndex"] == 0, r
print("ok: master routes and items on master are refused, and the project is unchanged")
