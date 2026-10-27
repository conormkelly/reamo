"""The release installer updates REAmo while REAPER is running it, and the uninstaller removes it.

The running binary is never written over: Windows refuses (a loaded DLL
is locked), and on Linux and macOS it changes code REAPER is executing.
The installer writes the new binary beside it and renames it into place;
on Windows the loaded DLL is first moved aside as old_reaper_reamo.*, which
REAmo deletes at its next start. Web files the new build doesn't have are
removed, and leftovers of earlier updates are cleaned up.

Versions before 0.8.1 put the web UI in reaper_www_root/web/, a name other
web control surfaces use too. Installing or uninstalling removes that
folder when it holds REAmo's UI.
"""
import glob
import os
import shutil

from reamo_client import BINARY_NAME, WEB_DIR, WINDOWS, Client, reaper
from release_package import BUILT, make_package, run_script

RES = reaper("return reaper.GetResourcePath()")
PLUGINS = os.path.join(RES, "UserPlugins")
BINARY = os.path.join(PLUGINS, BINARY_NAME)
EXT = os.path.splitext(BINARY_NAME)[1]
WEB = os.path.join(RES, "reaper_www_root", "reamo")
OLD_WEB = os.path.join(RES, "reaper_www_root", "web")


def seed_old_web():
    """REAmo's UI where versions before 0.8.1 installed it."""
    os.makedirs(os.path.join(OLD_WEB, "assets"), exist_ok=True)
    shutil.copy(os.path.join(WEB_DIR, "index.html"), OLD_WEB)
    open(os.path.join(OLD_WEB, "assets", "index-OLDBUILD.js"), "w").write("old")


def ours():
    return sorted(n for n in os.listdir(PLUGINS) if "reamo" in n)


with Client(timeout=10) as c:
    c.wait_event("trackSkeleton")

    # Leftovers of earlier updates, a hashed asset an old build had, and the
    # UI where an older version installed it.
    for name in (f"old_reaper_reamo.1761400000{EXT}", "reamo_install.tmp"):
        open(os.path.join(PLUGINS, name), "w").write("leftover")
    os.makedirs(os.path.join(WEB, "assets"), exist_ok=True)
    stale = os.path.join(WEB, "assets", "index-OLDBUILD.js")
    open(stale, "w").write("old")
    seed_old_web()
    original = open(BINARY, "rb").read()
    before = os.stat(BINARY).st_ino

    make_package("9.9.9-test")
    run_script("Install_REAmo.lua", "Return")
    run_script("Install_REAmo.lua", "Return")  # again, before any restart

    assert c.command("debug/memoryStats")["success"], "REAPER stopped answering after the install"
    assert open(BINARY, "rb").read() == open(BUILT, "rb").read()
    if WINDOWS:
        # The loaded DLL can only be moved aside; it stays until REAPER
        # restarts. Earlier leftovers, not loaded, are gone.
        aside = glob.glob(os.path.join(PLUGINS, f"old_reaper_reamo.*{EXT}"))
        assert len(aside) == 1 and "1761400000" not in aside[0], ours()
        assert open(aside[0], "rb").read() == original, "the DLL moved aside isn't the one REAPER loaded"
        assert ours() == sorted([BINARY_NAME, os.path.basename(aside[0])]), ours()
    else:
        assert os.stat(BINARY).st_ino != before, "the running binary was written over instead of replaced"
        assert ours() == [BINARY_NAME], ours()
    assert not os.path.exists(stale), "a stale web file from an old build was kept"
    assert os.path.exists(os.path.join(WEB, "index.html"))
    assert not os.path.exists(OLD_WEB), "REAmo's UI from an older version was left in reaper_www_root/web/"
    assert os.path.exists(os.path.join(RES, "Effects", "REAmo", "PitchDetect.jsfx"))
    print(f"installed twice over the running extension: plugins {ours()}")

    # Someone on an older version who uninstalls with this package.
    seed_old_web()
    run_script("Uninstall_REAmo.lua", "Return", "Return")  # confirm, then the result
    assert c.command("debug/memoryStats")["success"], "REAPER stopped answering after the uninstall"
    gone = [p for p in (BINARY, WEB, OLD_WEB, os.path.join(RES, "Effects", "REAmo")) if os.path.exists(p)]
    assert not gone, f"left behind: {gone}"
    if WINDOWS:
        # Only the DLL REAPER still has loaded, moved aside until it restarts.
        assert len(ours()) == 1 and ours()[0].startswith("old_reaper_reamo."), ours()
    else:
        assert ours() == [], ours()
    print(f"uninstalled; plugins {ours()}")
