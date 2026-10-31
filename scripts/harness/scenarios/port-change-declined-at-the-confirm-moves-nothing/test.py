"""Change Server Port asks before it moves the server, and anything but Yes
moves nothing: the server stays on its port and no port is saved.

Moving the port gives phones a new address, which loses their home-screen
app and the settings they saved, so a user who declines keeps both.
"""
import time

from reamo_client import PORT, WINDOWS, Client, press, reaper, screenshot, submit, windows

NEW = 9301
CONFIRM = "REAmo Port Change"


def wait_window(title, timeout=15):
    deadline = time.time() + timeout
    while title not in windows():
        assert time.time() < deadline, f"no {title!r} window; windows: {windows()}"
        time.sleep(0.1)


def wait_gone(title, timeout=5):
    """A dialog that has ended can stay listed for a moment."""
    deadline = time.time() + timeout
    while title in windows():
        assert time.time() < deadline, f"{title!r} is still open; windows: {windows()}"
        time.sleep(0.1)


def click_no():
    """Click the confirm's No, as a user would. SWELL's message box focuses
    its default button, Yes, and Tab moves focus to No."""
    if WINDOWS:
        import win_desktop
        hwnd = next(w for w, t in win_desktop.visible_windows() if t == CONFIRM)
        win_desktop.click_button(hwnd, "No")
    else:
        press(CONFIRM, "Tab", "space")


def decline(how, answer):
    """Change the port to NEW, answer the confirm with `answer`, and check
    REAmo stayed where it was."""
    pending = submit('reaper.Main_OnCommand(reaper.NamedCommandLookup("_REAMO_CHANGE_PORT"), 0)')
    wait_window("REAmo Server Port")
    press("REAmo Server Port", "ctrl+a", *list(str(NEW)), "Return")
    wait_window(CONFIRM)
    screenshot(f"confirm-{how}")
    answer()
    pending.result(10)  # the action has returned: no result message followed
    wait_gone(CONFIRM)

    with Client() as c:
        c.wait_event("trackSkeleton")
    saved = reaper('return reaper.GetExtState("Reamo", "ServerPort")')
    assert saved != str(NEW), f"{how}: the declined port was saved: {saved!r}"
    print(f"ok: {how} left REAmo on {PORT}, saved port {saved!r}")


with Client() as c:
    c.wait_event("trackSkeleton")

decline("No", click_no)
if not WINDOWS:
    # SWELL's Yes/No box also closes on Escape. Windows' has no Cancel
    # button, so Escape doesn't close it.
    decline("Escape", lambda: press(CONFIRM, "Escape"))
