"""Moving or recolouring a marker from a phone keeps the name the user typed in REAPER.

marker/update has PATCH semantics: fields the client leaves out keep their
REAPER value. The marker drag (ModalRoot) sends only `position`; the colour
picker (MarkerInfoBar) sends the current name back with the new colour.
Neither may shorten a name REAPER holds.
"""
import time
from reamo_client import Client, reaper

NAME = "Verse 1 - lead vocal comp from take 3, double the last line, ad-lib out"
assert len(NAME.encode()) > 64

NAME_OF_1 = """
local i = 0
while true do
  local ok, isrgn, pos, _, name, id = reaper.EnumProjectMarkers(i)
  if ok == 0 then return nil end
  if not isrgn and id == 1 then return {pos, name} end
  i = i + 1
end
"""


def wait_reaper(pred):
    deadline = time.time() + 2
    while True:
        got = reaper(NAME_OF_1)
        if pred(got) or time.time() > deadline:
            return got
        time.sleep(0.1)


with Client() as c:
    shown = {m["id"]: m for m in c.wait_event("markers")["payload"]["markers"]}
    assert shown[1]["name"] == NAME, f"markers event shows {shown[1]['name']!r}"

    # Drag the marker to 6 s (ModalRoot: position only).
    c.fire("marker/update", id=1, position=6.0)
    pos, name = wait_reaper(lambda g: g[0] == 6.0)
    print("after move:", pos, repr(name))
    assert pos == 6.0, pos
    assert name == NAME, f"moving the marker renamed it in REAPER to {name!r} ({len(name.encode())} bytes)"

    # Recolour it (MarkerInfoBar sends the name it shows plus the colour).
    c.fire("marker/update", id=1, name=NAME, color=0x1FF0000)
    c.drain(0.5)  # nothing observable to wait on if the name is kept
    pos, name = reaper(NAME_OF_1)
    print("after recolour:", pos, repr(name))
    assert name == NAME, f"recolouring the marker renamed it in REAPER to {name!r}"
