"""A phone page left open while REAPER restarts can reconnect by fetching
'/' again for the new run's token.

Each REAPER start makes a new session token and injects it into the
index.html it serves. The page's own copy then holds the old run's token,
whose hello is refused; the app recovers by fetching '/' (as the page does,
same-origin) for the token it should send instead. This pins both halves of
what that relies on: the old token is refused, and the token in a fresh
'/' is accepted.

What a refused hello delivers is recorded, not asserted: the INVALID_TOKEN
error and the 4001 close can be lost to a reset (the server closes with the
client's data unread), and the app doesn't depend on them.
"""
import time

from reamo_client import Client, Closed, fetch_token, reaper, restart_reaper, skip_unless_linux

skip_unless_linux("restarts the container's REAPER")


def hello(c, token):
    c.send({"type": "hello", "token": token, "protocolVersion": 1, "clientVersion": "harness"})


old_token = fetch_token()
with Client(hello=False, timeout=10) as phone:
    hello(phone, old_token)
    phone.wait_event("trackSkeleton")

restart_reaper()
assert reaper("return 1 + 1") == 2, "REAPER's RPC loop isn't serving after the restart"

new_token = fetch_token()
assert new_token != old_token, "REAPER restarted with the same session token"

# The page's own token, from the run before: refused.
with Client(hello=False, timeout=5) as stale:
    hello(stale, old_token)
    got = []
    try:
        while True:
            msg = stale._next_message(time.time() + 5)
            got.append(msg)
            assert msg.get("type") != "hello", f"a token from before the restart was accepted: {msg}"
    except TimeoutError:  # before OSError, its base class
        raise AssertionError(f"a stale hello was neither answered nor closed within 5 s; got {got}")
    except Closed as e:
        refusal = f"{[m.get('error', {}).get('code') for m in got]} then {e}"
    except OSError as e:  # a reset
        refusal = f"{[m.get('error', {}).get('code') for m in got]} then {type(e).__name__}"

# The token from fetching '/' again: accepted, and the session works.
with Client(hello=False, timeout=10) as phone:
    hello(phone, new_token)
    phone.wait_event("trackSkeleton")
    assert phone.command("debug/memoryStats")["success"]

print(f"restarted REAPER: the old token was refused ({refusal}); the token from a new GET / connected")
