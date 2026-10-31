"""A client that stops reading for good (a phone backgrounded mid-stream,
its socket left open) must not freeze REAPER, starve the other clients or
lock new ones out. The server gives up on it instead.

The stalled client keeps asking for large responses (getActions, ~700 KB
each), spread over many ticks: REAmo answers only about 4 a tick, so a
burst queues just ~3 MB, which the 4 MB send buffer absorbs (that is all
clients-slow-reader-does-not-stall-others reaches). Here the backlog grows
far past the send and receive buffers, so a send to that client that
blocks never returns, on whichever thread made it.
"""
import faulthandler
import socket
import time

from reamo_client import Client, reaper

# A frozen REAPER can hang this process too (a send to it, say): fail with
# every thread's stack rather than wait for the run's own timeout.
faulthandler.dump_traceback_later(120, exit=True)

FLOOD_SECONDS = 15
CHECK_TIMEOUT = 2.0

with Client() as stalled, Client() as phone:
    stalled.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    phone.wait_event("transport"); stalled.wait_event("transport")
    stalled.command("track/subscribe", range={"start": 0, "end": 8})
    stalled.sock.settimeout(CHECK_TIMEOUT)
    reaper("reaper.OnPlayButton()")

    sent = 0
    dropped = None  # how the server ended the stalled connection, once it has
    failure = None
    worst_cmd = worst_rpc = 0.0
    t0 = time.time()
    n0 = len(phone.events)
    while time.time() - t0 < FLOOD_SECONDS and failure is None:
        if dropped is None:
            try:
                for _ in range(4):
                    stalled.send({"type": "command", "command": "action/getActions", "id": f"big{sent}"})
                    sent += 1
            except (socket.timeout, OSError) as e:
                dropped = f"send failed after {time.time() - t0:.1f} s: {e!r}"
        a = time.time()
        try:
            r = phone.command("debug/memoryStats", timeout=CHECK_TIMEOUT)
            assert r["success"], r
            worst_cmd = max(worst_cmd, time.time() - a)
            a = time.time()
            reaper("return reaper.GetPlayPosition()", timeout=CHECK_TIMEOUT)
            worst_rpc = max(worst_rpc, time.time() - a)
        except TimeoutError as e:
            failure = f"stalled at {a - t0:.1f} s, {sent} getActions sent: {e}"
            break
        phone.drain(0.2)
    secs = time.time() - t0
    transport = sum(1 for name, _ in phone.events[n0:] if name in ("transport", "tt"))

    # A new client must still get in: its upgrade needs the client list's
    # write lock, which a thread stuck sending holds shared.
    newcomer = None
    if failure is None:
        try:
            with Client(timeout=CHECK_TIMEOUT) as late:
                late.wait_event("transport")
        except (TimeoutError, OSError) as e:
            newcomer = repr(e)

    # The stalled client's backlog has passed the server's bound by now, so
    # the server must have ended the connection: after what was already in
    # flight, reading it reaches the end.
    if failure is None and dropped is None:
        end = time.time() + 10
        try:
            while time.time() < end:
                if not stalled.sock.recv(1 << 20):
                    dropped = "closed by the server"
                    break
        except ConnectionError as e:
            dropped = f"reset by the server: {e!r}"
        except (socket.timeout, OSError):
            pass

    print(f"healthy client: {transport / secs:.1f} transport events/s over {secs:.1f} s, "
          f"worst command {worst_cmd * 1000:.0f} ms, worst REAPER rpc {worst_rpc * 1000:.0f} ms, "
          f"{sent} getActions sent; stalled client: {dropped or 'still open'}; "
          f"new client: {newcomer or 'connected'}")
    assert failure is None, f"REAPER or the healthy client froze: {failure}"
    assert transport / secs > 10, "transport events to the healthy client dried up"
    assert worst_cmd < 1.0 and worst_rpc < 1.0, "REAPER or the healthy client stalled"
    assert newcomer is None, f"a new client couldn't connect: {newcomer}"
    assert dropped is not None, "the server kept a client that stopped reading"

reaper("reaper.OnStopButton()", timeout=20)
faulthandler.cancel_dump_traceback_later()
