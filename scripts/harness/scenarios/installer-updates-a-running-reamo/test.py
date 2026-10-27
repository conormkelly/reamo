"""The release installer updates REAmo while REAPER is running it, and the uninstaller removes it.

The running binary is never written over: Windows refuses (a loaded DLL
is locked), and on Linux and macOS it changes code REAPER is executing.
The installer writes the new binary beside it and renames it into place;
on Windows the loaded DLL is first moved aside as old_reaper_reamo.*, which
REAmo deletes at its next start. Web files the new build doesn't have are
removed, and leftovers of earlier updates are cleaned up.
"""
import glob
import os
import shutil
import time

from reamo_client import (BINARY_NAME, EFFECTS_DIR, EXT_DIR, WEB_DIR, WINDOWS, Client, press, reaper,
                          submit, windows)

RES = reaper("return reaper.GetResourcePath()")
PLUGINS = os.path.join(RES, "UserPlugins")
BINARY = os.path.join(PLUGINS, BINARY_NAME)
EXT = os.path.splitext(BINARY_NAME)[1]
WEB = os.path.join(RES, "reaper_www_root", "web")
PKG = "/tmp/reamo-package"
BUILT = os.path.join(EXT_DIR, BINARY_NAME)


def make_package(version):
    shutil.rmtree(PKG, ignore_errors=True)
    os.makedirs(os.path.join(PKG, "effects", "REAmo"))
    shutil.copy(os.path.join(EXT_DIR, "installer", "Install_REAmo.lua"), PKG)
    shutil.copy(os.path.join(EXT_DIR, "installer", "Uninstall_REAmo.lua"), PKG)
    with open(os.path.join(PKG, "README.txt"), "w") as f:
        f.write(f"REAmo v{version}\n")
    shutil.copy(BUILT, PKG)
    shutil.copytree(WEB_DIR, os.path.join(PKG, "web"))
    shutil.copy(os.path.join(EFFECTS_DIR, "REAmo", "PitchDetect.jsfx"), os.path.join(PKG, "effects", "REAmo"))


def run_script(name, *keys):
    """Run a package script as REAPER's Run ReaScript does, answering its dialogs."""
    path = os.path.abspath(os.path.join(PKG, name)).replace("\\", "/")
    cmd = reaper(f"return reaper.AddRemoveReaScript(true, 0, '{path}', true)")
    assert cmd, f"REAPER didn't register {name}"
    pending = submit(f"reaper.Main_OnCommand({cmd}, 0)")
    for key in keys:
        deadline = time.time() + 15
        while not any(w.startswith("REAmo") or w.startswith("Uninstall REAmo") for w in windows()):
            assert time.time() < deadline, f"{name} showed no dialog; windows: {windows()}"
            time.sleep(0.1)
        title = next(w for w in windows() if w.startswith("REAmo") or w.startswith("Uninstall REAmo"))
        time.sleep(0.3)
        press(title, key)
        time.sleep(0.5)
    pending.result(15)


def ours():
    return sorted(n for n in os.listdir(PLUGINS) if "reamo" in n)


with Client(timeout=10) as c:
    c.wait_event("trackSkeleton")

    # Leftovers of earlier updates, and a hashed asset an old build had.
    for name in (f"old_reaper_reamo.1761400000{EXT}", "reamo_install.tmp"):
        open(os.path.join(PLUGINS, name), "w").write("leftover")
    os.makedirs(os.path.join(WEB, "assets"), exist_ok=True)
    stale = os.path.join(WEB, "assets", "index-OLDBUILD.js")
    open(stale, "w").write("old")
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
    assert os.path.exists(os.path.join(RES, "Effects", "REAmo", "PitchDetect.jsfx"))
    print(f"installed twice over the running extension: plugins {ours()}")

    run_script("Uninstall_REAmo.lua", "Return", "Return")  # confirm, then the result
    assert c.command("debug/memoryStats")["success"], "REAPER stopped answering after the uninstall"
    gone = [p for p in (BINARY, WEB, os.path.join(RES, "Effects", "REAmo")) if os.path.exists(p)]
    assert not gone, f"left behind: {gone}"
    if WINDOWS:
        # Only the DLL REAPER still has loaded, moved aside until it restarts.
        assert len(ours()) == 1 and ours()[0].startswith("old_reaper_reamo."), ours()
    else:
        assert ours() == [], ours()
    print(f"uninstalled; plugins {ours()}")
