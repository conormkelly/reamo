"""Moving an item to a track that was deleted moments earlier is refused, never a crash.

Two people on one session: one drags an item to the "Bus" track on the
phone just as the other deletes that track in REAPER. The destination
GUID still resolves in the extension's track cache until the cache is
rebuilt, so the command must check that REAPER still has that track
before handing the pointer to REAPER.
"""
import time

from reamo_client import Client, reaper

with Client() as c:
    item_guid = c.wait_event("items")["payload"]["items"][0]["guid"]
    hits = 0
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
        # Delete it in REAPER, and race a move to it from the phone.
        pending_delete = __import__("reamo_client").submit(
            "reaper.DeleteTrack(reaper.GetTrack(0, reaper.CountTracks(0) - 1))")
        for _ in range(6):
            c.fire("item/moveByGuid", guid=item_guid, destTrackGuid=guid)
            time.sleep(0.005)
        pending_delete.result()
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
            raise AssertionError(f"attempt {attempt}: the item went down with the deleted track")
        if where != "Source":
            # It reached the Bus before the delete; put it back for the next round.
            hits += 1
            reaper(f"""local it
              for i = 0, reaper.CountMediaItems(0) - 1 do
                local x = reaper.GetMediaItem(0, i)
                if select(2, reaper.GetSetMediaItemInfo_String(x, "GUID", "", false)) == "{item_guid}" then it = x end
              end
              reaper.MoveMediaItemToTrack(it, reaper.GetTrack(0, 0))""")
    print(f"30 races survived; {hits} moves landed before the delete")
