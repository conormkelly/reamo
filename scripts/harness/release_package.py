"""Build a release package from this run's build and run its scripts in REAPER.

    from release_package import make_package, run_script
    make_package("9.9.9-test")                     # laid out as the release zip is
    run_script("Install_REAmo.lua", "Return")      # answering each dialog with a key
"""
import os
import shutil
import time

from reamo_client import BINARY_NAME, EXT_DIR, WEB_DIR, press, reaper, submit, windows

PKG = "/tmp/reamo-package"
BUILT = os.path.join(EXT_DIR, BINARY_NAME)


def make_package(version):
    shutil.rmtree(PKG, ignore_errors=True)
    os.makedirs(PKG)
    shutil.copy(os.path.join(EXT_DIR, "installer", "Install_REAmo.lua"), PKG)
    shutil.copy(os.path.join(EXT_DIR, "installer", "Uninstall_REAmo.lua"), PKG)
    with open(os.path.join(PKG, "README.txt"), "w") as f:
        f.write(f"REAmo v{version}\n")
    shutil.copy(BUILT, PKG)
    shutil.copytree(WEB_DIR, os.path.join(PKG, "reamo"))


def run_script(name, *keys):
    """Run a package script as REAPER's Run ReaScript does, answering its
    dialogs. Returns the titles of the dialogs answered, in order: the
    installer titles its failure dialog "REAmo Install: problems"."""
    path = os.path.abspath(os.path.join(PKG, name)).replace("\\", "/")
    cmd = reaper(f"return reaper.AddRemoveReaScript(true, 0, '{path}', true)")
    assert cmd, f"REAPER didn't register {name}"
    pending = submit(f"reaper.Main_OnCommand({cmd}, 0)")
    titles = []
    for key in keys:
        deadline = time.time() + 15
        while not any(w.startswith("REAmo") or w.startswith("Uninstall REAmo") for w in windows()):
            assert time.time() < deadline, f"{name} showed no dialog; windows: {windows()}"
            time.sleep(0.1)
        title = next(w for w in windows() if w.startswith("REAmo") or w.startswith("Uninstall REAmo"))
        titles.append(title)
        time.sleep(0.3)
        press(title, key)
        time.sleep(0.5)
    pending.result(15)
    return titles
