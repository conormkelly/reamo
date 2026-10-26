"""Show Connection QR Code offers the address this computer routes through.

A computer lists virtual adapters (VirtualBox's 192.168.56.1, Hyper-V's
vEthernet, Docker bridges) beside its real one, often ahead of it, and a
phone can't reach them. Here a VirtualBox-like adapter is listed before the
LAN adapter that carries the default route: the QR code shows the LAN
address, with the other one arrow away. With no default route there's
nothing to go on, and the adapters keep the order the OS lists them in.
"""
import subprocess
import time

from reamo_client import Client, reaper, windows


def ip(*args):
    subprocess.run(["ip", *args], check=True)


def adapter(name, address):
    ip("link", "add", name, "type", "dummy")
    ip("addr", "add", address, "dev", name)
    ip("link", "set", name, "up")


def show_qr_title():
    reaper('reaper.Main_OnCommand(reaper.NamedCommandLookup("_REAMO_SHOW_QR_CODE"), 0)')
    deadline = time.time() + 10
    while True:
        titles = [t for t in windows() if t.startswith("REAmo - ")]
        if titles:
            return titles[0]
        assert time.time() < deadline, f"no QR window; windows: {windows()}"
        time.sleep(0.1)


adapter("vbox0", "192.168.56.1/24")
adapter("lan0", "192.168.1.18/24")
ip("route", "add", "default", "via", "192.168.1.1", "dev", "lan0")

with Client(timeout=10) as c:
    c.wait_event("trackSkeleton")

    title = show_qr_title()
    assert title == "REAmo - LAN: 192.168.1.18 (1/2)", title

    ip("route", "del", "default")
    reaper('reaper.Main_OnCommand(reaper.NamedCommandLookup("_REAMO_SHOW_QR_CODE"), 0)')
    deadline = time.time() + 10
    while "REAmo - LAN: 192.168.56.1 (1/2)" not in windows():
        assert time.time() < deadline, f"QR window didn't fall back to the OS's order; windows: {windows()}"
        time.sleep(0.1)

    assert c.command("debug/memoryStats")["success"]
    print(f"with a default route: {title}")
