"""Extensions > REAmo > Open Log Folder opens the folder, or says where it is.

The file browser runs as its own process that REAPER never waits on. Where
it can't run (no xdg-open in this container), a message gives the folder's
path. Either way REAPER keeps answering.
"""
import shutil
import time

from reamo_client import Client, press, reaper, submit, windows

with Client(timeout=10) as c:
    c.wait_event("trackSkeleton")
    pending = submit('reaper.Main_OnCommand(reaper.NamedCommandLookup("_REAMO_OPEN_LOG_FOLDER"), 0)')
    has_opener = shutil.which("xdg-open") is not None
    if not has_opener:
        deadline = time.time() + 10
        while not any(w == "REAmo" for w in windows()):
            assert time.time() < deadline, f"no message with the log's path; windows: {windows()}"
            time.sleep(0.1)
        press("REAmo", "Return")
    pending.result(10)
    assert c.command("debug/memoryStats")["success"]
    log = reaper("local f = io.open(reaper.GetResourcePath() .. '/Logs/reamo.log'); local s = f:read('a'); f:close(); return s")
    if not has_opener:
        assert "Open Log Folder: couldn't run xdg-open: not installed" in log, log[-1500:]
    print(f"xdg-open present: {has_opener}")
