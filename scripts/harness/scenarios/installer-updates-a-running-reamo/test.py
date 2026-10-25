"""The release installer updates REAmo while REAPER is running it, and the uninstaller removes it.

The installer used to open the running binary and write the new one over
it. Windows refuses (the DLL is locked), and on Linux and macOS it changes
code REAPER is executing. It now writes the new binary beside the old one
and renames it into place: the running copy keeps its file until REAPER
restarts. Web files the new build doesn't have are removed, and leftovers
of earlier updates are cleaned up.
"""
import os
import shutil
import time

from reamo_client import Client, press, reaper, submit, windows

RES = reaper("return reaper.GetResourcePath()")
PLUGINS = os.path.join(RES, "UserPlugins")
BINARY = os.path.join(PLUGINS, "reaper_reamo.so")
WEB = os.path.join(RES, "reaper_www_root", "web")
PKG = "/tmp/reamo-package"


def make_package(version):
    shutil.rmtree(PKG, ignore_errors=True)
    os.makedirs(os.path.join(PKG, "effects", "REAmo"))
    shutil.copy("/ext/installer/Install_REAmo.lua", PKG)
    shutil.copy("/ext/installer/Uninstall_REAmo.lua", PKG)
    with open(os.path.join(PKG, "README.txt"), "w") as f:
        f.write(f"REAmo v{version}\n")
    shutil.copy("/ext/reaper_reamo.so", PKG)
    shutil.copytree("/web", os.path.join(PKG, "web"))
    shutil.copy("/effects/REAmo/PitchDetect.jsfx", os.path.join(PKG, "effects", "REAmo"))


def run_script(name, *keys):
    """Run a package script as REAPER's Run ReaScript does, answering its dialogs."""
    cmd = reaper(f"return reaper.AddRemoveReaScript(true, 0, '{PKG}/{name}', true)")
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


with Client(timeout=10) as c:
    c.wait_event("trackSkeleton")

    # Leftovers of earlier updates, and a hashed asset an old build had.
    for name in ("old_reaper_reamo.1761400000.so", "reamo_install.tmp"):
        open(os.path.join(PLUGINS, name), "w").write("leftover")
    os.makedirs(os.path.join(WEB, "assets"), exist_ok=True)
    stale = os.path.join(WEB, "assets", "index-OLDBUILD.js")
    open(stale, "w").write("old")
    before = os.stat(BINARY).st_ino

    make_package("9.9.9-test")
    run_script("Install_REAmo.lua", "Return")
    run_script("Install_REAmo.lua", "Return")  # again, before any restart

    assert c.command("debug/memoryStats")["success"], "REAPER stopped answering after the install"
    after = os.stat(BINARY)
    assert after.st_ino != before, "the running binary was written over instead of replaced"
    assert open(BINARY, "rb").read() == open("/ext/reaper_reamo.so", "rb").read()
    left = sorted(n for n in os.listdir(PLUGINS) if "reamo" in n)
    assert left == ["reaper_reamo.so"], left
    assert not os.path.exists(stale), "a stale web file from an old build was kept"
    assert os.path.exists(os.path.join(WEB, "index.html"))
    assert os.path.exists(os.path.join(RES, "Effects", "REAmo", "PitchDetect.jsfx"))
    print(f"installed twice over the running extension: plugins {left}")

    run_script("Uninstall_REAmo.lua", "Return", "Return")  # confirm, then the result
    assert c.command("debug/memoryStats")["success"], "REAPER stopped answering after the uninstall"
    gone = [p for p in (BINARY, WEB, os.path.join(RES, "Effects", "REAmo")) if os.path.exists(p)]
    assert not gone, f"left behind: {gone}"
    print("uninstalled")
