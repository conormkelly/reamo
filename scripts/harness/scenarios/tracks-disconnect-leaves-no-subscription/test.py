"""A phone that drops off the network (socket closed without unsubscribing) leaves
nothing behind: a client that connects next gets no tracks/meters until it
subscribes (after the 500 ms track grace period), and 40 connect-subscribe-drop cycles don't exhaust client slots."""
import time

from reamo_client import Client

for i in range(40):
    a = Client()
    a.wait_event("trackSkeleton")
    r = a.command("track/subscribe", range={"start": 0, "end": 4})
    assert r["success"], f"cycle {i}: {r}"
    a.wait_event("tracks")
    a.close()  # no unsubscribe, no close frame: Wi-Fi went away

time.sleep(2.0)  # disconnect detection + 500 ms grace + 1 Hz grace cleanup

with Client() as b:
    b.wait_event("trackSkeleton")
    b.drain(1.0)
    # An empty tracks event (just the track total) is fine; track data or meters are not.
    leaked = [n for n, m in b.events if (n == "tracks" and m["payload"]["tracks"]) or n == "meters"]
    print(f"new client, not subscribed: {len(leaked)} tracks/meters events in 1 s")
    assert not leaked, f"unsubscribed client received {len(leaked)} tracks/meters events"
    r = b.command("track/subscribe", range={"start": 1, "end": 2})
    assert r["success"], r
    t = []
    while not t:
        t = b.wait_event("tracks")["payload"]["tracks"]
    assert [x["idx"] for x in t] == [1, 2], t
