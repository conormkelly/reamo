"""Changing REAmo's port to one something else holds keeps the server up.

Extensions > REAmo > Change Server Port stopped the running server before
starting one on the new port. If the new port was taken, REAmo served
nothing until REAPER restarted, while the dialog said "Server restarted"
and the taken port was saved for next time.
"""
import socket
import time

from reamo_client import PORT, Client, press, reaper, screenshot, submit, windows

BUSY = 9300
CONFIRM = "REAmo Port Change"


def wait_window(title, timeout=15):
    deadline = time.time() + timeout
    while title not in windows():
        assert time.time() < deadline, f"no {title!r} window; windows: {windows()}"
        time.sleep(0.1)


def change_port(port):
    """Enter `port` in Change Server Port, answer Yes to the confirm, and
    wait for the result message (titled just "REAmo")."""
    wait_window("REAmo Server Port")
    press("REAmo Server Port", "ctrl+a", *list(str(port)), "Return")
    wait_window(CONFIRM)
    press(CONFIRM, "Return")  # Yes is the default button
    wait_window("REAmo")
    time.sleep(0.5)


squatter = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
squatter.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
squatter.bind(("0.0.0.0", BUSY))
squatter.listen(1)

with Client() as c:
    c.wait_event("trackSkeleton")

pending = submit('reaper.Main_OnCommand(reaper.NamedCommandLookup("_REAMO_CHANGE_PORT"), 0)')
change_port(BUSY)
print(f"windows after entering the busy port: {windows()}")
press("REAmo", "Return")
pending.result(10)

# Still serving on the old port.
with Client() as c:
    c.wait_event("trackSkeleton")
    assert c.command("debug/memoryStats")["success"]

saved = reaper('return reaper.GetExtState("Reamo", "ServerPort")')
assert saved != str(BUSY), f"the port that failed was saved: {saved!r}"
squatter.close()
print(f"ok: still serving on {PORT}, saved port {saved!r}")

# A free port: the server moves there, and the port is saved.
FREE = 9301
pending = submit('reaper.Main_OnCommand(reaper.NamedCommandLookup("_REAMO_CHANGE_PORT"), 0)')
change_port(FREE)
screenshot("moved")
press("REAmo", "Return")
pending.result(10)
with Client(port=FREE) as c:
    c.wait_event("trackSkeleton")
saved = reaper('return reaper.GetExtState("Reamo", "ServerPort")')
assert saved == str(FREE), saved
print(f"ok: moved to {FREE} and saved it")
