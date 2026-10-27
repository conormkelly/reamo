"""The routing view of a bus with 80 receives shows all 80.

Opening the routing modal on an orchestral template's reverb bus subscribes
to its routing; the routing_state event must arrive and list every receive.
"""
import time
from reamo_client import Client, oracle

want = int(oracle()["receives"])
with Client() as c:
    g = c.wait_event("trackSkeleton")["payload"]["tracks"][1]["g"]
    time.sleep(1.2)  # GUID cache settles ~1 s after REAPER starts
    assert c.command("routing/subscribe", trackGuid=g)["success"]
    try:
        ev = c.wait_event("routing_state", timeout=3)["payload"]
    except TimeoutError:
        raise AssertionError(f"no routing_state at all for a bus with {want} receives") from None
    print("receives shown:", len(ev["receives"]), "of", want)
    assert len(ev["receives"]) == want
