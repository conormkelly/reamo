"""A real saved project with a non-default start measure: bar numbers match REAPER's own labels."""
from reamo_client import Client, oracle

truth = oracle()
labels = {float(k.split("@")[1]): v for k, v in truth.items() if k.startswith("label@")}
print("REAPER labels:", {round(t, 3): v for t, v in sorted(labels.items())})

with Client(timeout=8) as c:
    skel = c.wait_event("trackSkeleton")["payload"]["tracks"]
    print(f"tracks={len(skel) - 1}")
    mismatches = []
    for t, label in sorted(labels.items()):
        bar = int(label.split(".")[0])                # "-4.1.00" -> -4
        got = c.command("tempo/barsToTime", bar=bar)["payload"]["time"]
        if abs(got - t) > 1e-3:
            mismatches.append(f"bar {bar}: REAPER labels t={t:.3f}s, barsToTime -> {got:.3f}s")
        beats = c.command("tempo/timeToBeats", time=t)["payload"]
        print(f"  t={t:7.3f}s REAPER '{label}'  barsToTime({bar})={got:7.3f}  timeToBeats={beats}")
    n = len(skel) - 1
    assert c.command("peaks/subscribe", range={"start": 1, "end": n},
                     viewport={"start": 0, "end": 30, "widthPx": 400})["success"]
    c.fire("transport/play"); c.drain(2); c.fire("transport/stop"); c.drain(1)
    assert not mismatches, "\n".join(mismatches)
