"""Every protocol operation against a project saved by REAPER 6 on Windows,
with missing plugins and media (see corpus/legacy-v6.lua).

While each load dialog is up, REAPER's main thread is inside the dialog. A
phone that connects then (a reconnect while the user deals with the dialog
on the desktop) must still be accepted, and REAPER must not die; the tour
afterwards requires every client to converge to the loaded project."""
import os
import time

from reamo_client import Client
from tour import main

during = []


def phone_connects(title):
    t0 = time.time()
    with Client() as c:  # HTTP token fetch, upgrade and hello: the server's own thread
        try:
            c.wait_event("trackSkeleton", timeout=3.0)
            snapshot = f"snapshot after {time.time() - t0:.2f}s"
        except TimeoutError:
            snapshot = "no snapshot while the dialog is up"
    during.append(f"{title!r}: connected, {snapshot}")


try:
    main("/tmp/corpus/legacy-v6/legacy-v6.RPP", "legacy-v6", only=os.environ.get("TOUR_ONLY", "").split() or None,
         on_dialog=phone_connects)
finally:
    print("phones connecting during load dialogs:\n    " + "\n    ".join(during or ["no dialog appeared"]))
