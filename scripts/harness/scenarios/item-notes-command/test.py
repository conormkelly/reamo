"""item/getNotes returns long notes intact (or a clean error), never a crash."""
from reamo_client import Client

with Client() as c:
    short = c.command("item/getNotes", trackIdx=1, itemIdx=0)
    assert short["success"] and len(short["payload"]["notes"]) == 500, short
    long_ = c.command("item/getNotes", trackIdx=1, itemIdx=1)
    print(f"long note: success={long_['success']} len={len((long_.get('payload') or {}).get('notes', ''))}")
    assert long_["success"] and len(long_["payload"]["notes"]) == 20000, "long note truncated or failed"
