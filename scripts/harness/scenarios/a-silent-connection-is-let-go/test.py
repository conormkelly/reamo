"""A connection that never sends a request is let go after the request
timeout (5 s).

Each open connection holds a slot (and on Windows a thread). A page left
open in a browser, or a hostile one, can open connections and go quiet;
if they were never let go, they would fill the slots and lock the phone
out.
"""
import socket
import time

from reamo_client import HOST, PORT, Client

with Client(timeout=10) as phone:
    phone.wait_event("trackSkeleton")
    with socket.create_connection((HOST, PORT), timeout=15) as s:
        start = time.time()
        try:
            data = s.recv(100)
            outcome = f"closed by the server ({data[:30]!r})"
        except socket.timeout:
            outcome = "still open"
        except ConnectionResetError:
            outcome = "reset by the server"
        took = time.time() - start
    assert outcome != "still open", f"a silent connection was still open after {took:.0f} s"
    assert took < 9, f"a silent connection was let go only after {took:.1f} s ({outcome})"
    assert phone.command("debug/memoryStats")["success"]
    print(f"silent connection {outcome} after {took:.1f} s")
