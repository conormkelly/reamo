"""Changing the port with a phone connected ends the phone's connection
and serves on the new port, without REAPER waiting on the old server.

Restarting the server stops the old one, which must end every connection
it has: the phone's WebSocket is blocked reading, and a server that can't
wake it waits on it forever, freezing REAPER's UI in the port dialog.
"""
import time

from reamo_client import Client, Closed, press, reaper, submit, windows

FREE = 9301


def wait_window(title, timeout=15):
    deadline = time.time() + timeout
    while title not in windows():
        assert time.time() < deadline, f"no {title!r} window; windows: {windows()}"
        time.sleep(0.1)


with Client(timeout=10) as phone:
    phone.wait_event("trackSkeleton")

    start = time.time()
    pending = submit('reaper.Main_OnCommand(reaper.NamedCommandLookup("_REAMO_CHANGE_PORT"), 0)')
    wait_window("REAmo Server Port")
    press("REAmo Server Port", "ctrl+a", *list(str(FREE)), "Return")
    wait_window("REAmo Port Change")
    press("REAmo Port Change", "Return")  # Yes is the default button
    wait_window("REAmo")  # the result message (titled just that), once the old server has stopped
    took = time.time() - start
    press("REAmo", "Return")
    pending.result(10)
    assert took < 8, f"the port change took {took:.1f} s"

    try:
        phone.drain(3)
        ended = False
    except (Closed, ConnectionError, OSError):
        ended = True
    assert ended, "the phone's connection to the old server is still open"

assert reaper("return 1 + 1") == 2
with Client(port=FREE) as c:
    c.wait_event("trackSkeleton")
    assert c.command("debug/memoryStats")["success"]
print(f"port change with a phone connected took {took:.1f} s; the phone was disconnected")
