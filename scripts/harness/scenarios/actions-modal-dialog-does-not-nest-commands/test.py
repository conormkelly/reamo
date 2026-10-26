"""A phone action that opens a modal dialog (a script asking a question,
File > Save as, a plugin's licence nag) keeps REAPER inside that command
until the dialog closes. A command another phone sends meanwhile must not
run inside it: the first command may still hold a track the second deletes,
and their undo blocks would nest."""
import time

from reamo_client import Client, press, reaper, windows

TITLE = "REAmo modal probe"

cmd_id = int(reaper('return reaper.GetExtState("harness", "modal_cmd")'))
guid = reaper('return reaper.GetTrackGUID(reaper.GetTrack(0, 0))')

with Client() as c:
    c.wait_event("transport")
    c.send({"type": "command", "command": "action/execute", "id": "modal", "commandId": cmd_id})
    deadline = time.time() + 15
    while not any(TITLE in w for w in windows()):
        assert time.time() < deadline, f"the script's dialog never opened; windows: {windows()}"
        time.sleep(0.1)

    c.send({"type": "command", "command": "track/setMute", "id": "inner", "trackGuid": guid})
    order = []
    events_during = 0
    end = time.time() + 3
    while time.time() < end:
        try:
            msg = c._next_message(end)
        except TimeoutError:
            break
        if msg.get("type") == "response":
            order.append(msg["id"])
        elif msg.get("type") == "event":
            events_during += 1
    print(f"while the dialog was open: responses {order}, {events_during} events")

    press(TITLE, "Return")
    end = time.time() + 10
    while len(order) < 2 and time.time() < end:
        try:
            msg = c._next_message(end)
        except TimeoutError:
            break
        if msg.get("type") == "response":
            order.append(msg["id"])
    print(f"responses in order: {order}")

    assert order == ["modal", "inner"], \
        f"a command ran inside another one that was waiting on a dialog: {order}"
    print("ok: the second command waited for the dialog to close")
