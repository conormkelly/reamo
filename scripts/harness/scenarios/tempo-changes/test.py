"""Tempo map and bar conversions stay consistent across tempo/meter changes and a negative start measure."""
from reamo_client import Client

with Client() as c:
    tm = c.wait_event("tempoMap")["payload"]
    print("tempo markers:", len(tm.get("markers", tm.get("tempos", []))))
    times = []
    for bar in (-4, -1, 0, 1, 5, 12):
        r = c.command("tempo/barsToTime", bar=bar)
        assert r["success"], (bar, r)
        times.append(r["payload"]["time"])
    print("bars -> seconds:", [round(t, 3) for t in times])
    assert times == sorted(times), "bar times must increase with bar number"
    for t in (0.0, 9.0, 25.0):
        r = c.command("tempo/timeToBeats", time=t)
        assert r["success"], (t, r)
    c.fire("transport/seekBeats", bar=5)  # fire-and-forget, as the UI sends it
    c.drain(1)
