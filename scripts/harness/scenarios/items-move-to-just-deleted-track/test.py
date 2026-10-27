"""Moving an item to a track that was deleted moments earlier is refused, never a crash.

Two people on one session: one drags an item to the "Bus" track on the
phone just after the other deletes that track in REAPER. The destination
GUID still resolves in the extension's track cache until the cache is
rebuilt, so the command must check that REAPER still has that track
before handing the pointer to REAPER, and leave the item where it was.

The moves are sent once the delete has happened: sent alongside it, they
can as well land first, and then the item rightly goes with its track.
"""
import time

from reamo_client import Client, reaper

with Client() as c:
    item_guid = c.wait_event("items")["payload"]["items"][0]["guid"]
    for attempt in range(30):
        guid = reaper("""
            reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
            local t = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
            reaper.GetSetMediaTrackInfo_String(t, "P_NAME", "Bus", true)
            return reaper.GetTrackGUID(t)""")
        # Wait until the extension's cache knows the new track.
        deadline = time.time() + 3
        while time.time() < deadline:
            r = c.command("track/setMute", trackGuid=guid, mute=0)
            if r.get("success"):
                break
            time.sleep(0.05)
        # Delete it in REAPER; then, while the cache still has it, move to it.
        reaper("reaper.DeleteTrack(reaper.GetTrack(0, reaper.CountTracks(0) - 1))")
        for _ in range(6):
            c.fire("item/moveByGuid", guid=item_guid, destTrackGuid=guid)
            time.sleep(0.005)
        c.drain(0.1)
        where = reaper(f"""
            for i = 0, reaper.CountMediaItems(0) - 1 do
              local it = reaper.GetMediaItem(0, i)
              if select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)) == "{item_guid}" then
                return select(2, reaper.GetTrackName(reaper.GetMediaItemTrack(it)))
              end
            end
            return "missing" """)
        if where == "missing":
            raise AssertionError(f"attempt {attempt}: the item went to the deleted track")
        assert where == "Source", f"attempt {attempt}: the item moved to {where!r}"
    print("30 moves to a just-deleted track refused; the item stayed on Source")
