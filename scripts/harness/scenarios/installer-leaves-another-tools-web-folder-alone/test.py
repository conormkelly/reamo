"""Installing and uninstalling REAmo leaves another tool's reaper_www_root/web/ alone.

REAmo's UI lives in reaper_www_root/reamo/. Versions before 0.8.1 used
reaper_www_root/web/, which the installer and uninstaller still clean up,
but only when it holds REAmo's page. Other web control surfaces use web/
too, and a page that merely mentions REAmo is still theirs.
"""
import os

from reamo_client import Client, reaper
from release_package import make_package, run_script

RES = reaper("return reaper.GetResourcePath()")
OTHER_WEB = os.path.join(RES, "reaper_www_root", "web")
OTHER_FILES = {
    "index.html": "<!doctype html><html><head><title>Stage Control</title></head>"
                  "<body>Works alongside REAmo.</body></html>",
    os.path.join("js", "app.js"): "console.log('stage control')",
}


def other_tool():
    found = {}
    for root, _, files in os.walk(OTHER_WEB):
        for name in files:
            path = os.path.join(root, name)
            found[os.path.relpath(path, OTHER_WEB)] = open(path).read()
    return found


with Client(timeout=10) as c:
    c.wait_event("trackSkeleton")
    for rel, text in OTHER_FILES.items():
        os.makedirs(os.path.dirname(os.path.join(OTHER_WEB, rel)), exist_ok=True)
        open(os.path.join(OTHER_WEB, rel), "w").write(text)

    make_package("9.9.9-test")
    run_script("Install_REAmo.lua", "Return")
    assert os.path.exists(os.path.join(RES, "reaper_www_root", "reamo", "index.html"))
    assert other_tool() == OTHER_FILES, f"the installer changed another tool's web/: {sorted(other_tool())}"

    run_script("Uninstall_REAmo.lua", "Return", "Return")  # confirm, then the result
    assert not os.path.exists(os.path.join(RES, "reaper_www_root", "reamo"))
    assert other_tool() == OTHER_FILES, f"the uninstaller changed another tool's web/: {sorted(other_tool())}"
    print("another tool's web/ survived an install and an uninstall")
