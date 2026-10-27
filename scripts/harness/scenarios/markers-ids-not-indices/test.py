"""marker/* commands address REAPER's marker numbers, not enumeration order.

The user deletes marker 2 in REAPER, so marker 3 is now the second marker
enumerated. The phone then goes to, moves (past marker 1) and deletes markers
by the ids the markers event gave it. A region numbered 2 must be untouched
throughout, and the markers event must follow every change.
"""
import time
from reamo_client import Client, reaper

STATE = """
local out = {}
local i = 0
while true do
  local ok, isrgn, pos, rend, name, id = reaper.EnumProjectMarkers(i)
  if ok == 0 then break end
  out[#out + 1] = string.format("%s%d@%g:%s", isrgn and "R" or "M", id, pos, name)
  i = i + 1
end
table.sort(out)
return table.concat(out, " ")
"""


def until(c, pred, what):
    deadline = time.time() + 2
    while True:
        c.drain(0.2)
        got = reaper(STATE)
        if pred(got) or time.time() > deadline:
            return got


def shown(c):
    return sorted((m["id"], m["position"], m["name"]) for m in c.latest_event("markers")["payload"]["markers"])


with Client() as c:
    c.wait_event("markers")
    reaper("reaper.DeleteProjectMarker(0, 2, false); reaper.UpdateTimeline()")
    s = until(c, lambda s: "M2@" not in s, "delete in REAPER")
    assert s == "M1@2:One M3@6:Three R2@3:Region Two", s
    c.drain(0.5)
    assert shown(c) == [(1, 2, "One"), (3, 6, "Three")], shown(c)

    c.fire("marker/goto", id=3)
    deadline = time.time() + 2
    while reaper("return reaper.GetCursorPosition()") != 6 and time.time() < deadline:
        time.sleep(0.1)
    assert reaper("return reaper.GetCursorPosition()") == 6, reaper("return reaper.GetCursorPosition()")

    # The deleted marker: region 2 (at 3 s) must not be used. marker/* take
    # their marker number in "id", which is also the wire's request-id field,
    # so these commands can never carry a response; check REAPER instead.
    c.fire("marker/goto", id=2)
    c.drain(0.5)
    assert reaper("return reaper.GetCursorPosition()") == 6, reaper("return reaper.GetCursorPosition()")

    c.fire("marker/update", id=3, position=1.0)  # past marker 1
    s = until(c, lambda s: "M3@1" in s, "move")
    print("after move:", s)
    assert s == "M1@2:One M3@1:Three R2@3:Region Two", s
    c.drain(0.5)
    assert shown(c) == [(1, 2, "One"), (3, 1, "Three")], shown(c)

    c.fire("marker/delete", id=1)
    s = until(c, lambda s: "M1@" not in s, "delete")
    print("after delete:", s)
    assert s == "M3@1:Three R2@3:Region Two", s
    c.drain(0.5)
    assert shown(c) == [(3, 1, "Three")], shown(c)
