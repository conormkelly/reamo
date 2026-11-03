"""Connections that hold a slot and never authenticate can't lock a phone out.

The server has 64 connection slots, shared by HTTP and WebSocket. Once they
are all taken it accepts nothing more, so a phone's connection waits in the
listen backlog until one frees. One host on the network could take every
slot with sockets that do nothing.

1. WebSocket: 64 sockets upgrade and never send hello (one sends pings
   instead, which must not keep it). Each must be closed with 4003 within
   the hello deadline (10 s) plus a tick, and a phone trying the way the web
   app does must then get in. A socket that sends its hello just inside the
   deadline must be kept.
2. HTTP: 64 connections trickle a request that never ends. The request
   timeout (5 s from accept) must close them, and a phone must then get in.
"""
import selectors
import socket
import threading
import time

from reamo_client import HOST, PORT, Client, Closed, fetch_token

SLOTS = 64
HELLO_DEADLINE_S = 10.0
LATE_HELLO_AT_S = 8.5  # a slow phone's hello, inside the deadline
# The web app's own limits, each attempt: CONNECT_TIMEOUT for the upgrade,
# HELLO_TIMEOUT for the reply (frontend/src/core/websocketMachine.ts).
ATTEMPT_TIMEOUT_S = 5.0
GIVE_UP_S = 30.0

problems = []
token = fetch_token()  # before the slots fill, as a page loaded earlier has it


def phone_gets_in(started):
    """Try as the web app does until a command is answered; seconds taken, or None."""
    while time.time() - started < GIVE_UP_S:
        try:
            c = Client(hello=False, timeout=ATTEMPT_TIMEOUT_S)
        except (OSError, RuntimeError, Closed):
            time.sleep(1.0)  # the app's first retry delay
            continue
        try:
            c.send({"type": "hello", "token": token, "protocolVersion": 1, "clientVersion": "harness"})
            r = c.command("debug/memoryStats", timeout=ATTEMPT_TIMEOUT_S)
            if r.get("success"):
                return time.time() - started
        except (OSError, TimeoutError, Closed):
            pass
        finally:
            c.close()
        time.sleep(1.0)
    return None


def close_code(exc):
    """The close code in reamo_client's Closed message, or what ended the socket."""
    text = str(exc)
    if text.startswith("close frame "):
        return int(text.split()[2], 16)
    return text


def watch(socks, results, stop):
    """Record, for each socket, when and how the server ended it."""
    sel = selectors.DefaultSelector()
    for i, c in enumerate(socks):
        c.sock.setblocking(False)
        sel.register(c.sock, selectors.EVENT_READ, i)
    left = len(socks)
    while left and not stop.is_set():
        for key, _ in sel.select(timeout=0.1):
            i = key.data
            c = socks[i]
            c.sock.setblocking(True)
            c.sock.settimeout(1.0)
            try:
                while True:
                    c._recv_frame()  # NOT_AUTHENTICATED replies to the pinger
                    if not c._buf:
                        break
                c.sock.setblocking(False)
                continue
            except Closed as e:
                results[i] = (time.time(), close_code(e))
            except OSError as e:
                results[i] = (time.time(), type(e).__name__)
            sel.unregister(c.sock)
            left -= 1


# ── 1. WebSockets that never say hello ────────────────────────────────
silent, opened = [], []
for i in range(SLOTS):
    try:
        silent.append(Client(hello=False, timeout=3))
        opened.append(time.time())
    except (OSError, RuntimeError, Closed) as e:
        print(f"socket {i} didn't upgrade: {e!r}")
        break
print(f"{len(silent)} sockets upgraded without a hello")

late = silent[0]   # says hello just inside the deadline
pinger = silent[1]  # sends pings, never a hello
others = silent[2:]
results = [None] * len(others) + [None]
stop = threading.Event()
watcher = threading.Thread(target=watch, args=(others + [pinger], results, stop), daemon=True)


def ping_until_closed():
    while not stop.is_set() and results[-1] is None:
        try:
            pinger.send({"type": "ping"})
        except OSError:
            return
        time.sleep(1.0)


pinging = threading.Thread(target=ping_until_closed, daemon=True)
watcher.start()
pinging.start()


def late_hello():
    time.sleep(max(0.0, opened[0] + LATE_HELLO_AT_S - time.time()))
    late.send({"type": "hello", "token": token, "protocolVersion": 1, "clientVersion": "harness"})


late_thread = threading.Thread(target=late_hello, daemon=True)
late_thread.start()

started = time.time()
took = phone_gets_in(started)
if took is None:
    problems.append(f"a phone was locked out for {GIVE_UP_S:.0f} s by {len(silent)} sockets that never said hello")
else:
    print(f"phone got in {took:.1f} s after the slots filled")
    if took > HELLO_DEADLINE_S + 6:
        problems.append(f"a phone got in only after {took:.1f} s (deadline {HELLO_DEADLINE_S:.0f} s)")

late_thread.join()
time.sleep(max(0.0, opened[1] + HELLO_DEADLINE_S + 2.0 - time.time()))
stop.set()
watcher.join(timeout=3)

codes = {}
watched_opened = opened[2:] + [opened[1]]
for r, t0 in zip(results, watched_opened):
    if r is not None:
        when, code = r
        codes.setdefault(code, []).append(when - t0)
unclosed = sum(r is None for r in results)
for code, ages in sorted(codes.items(), key=str):
    print(f"closed with {code}: {len(ages)} sockets, {min(ages):.1f}-{max(ages):.1f} s after the upgrade")
if unclosed:
    problems.append(f"{unclosed} of {len(results)} sockets that never said hello were still open "
                    f"{HELLO_DEADLINE_S + 2:.0f} s after the upgrade")
for code, ages in codes.items():
    if code != 4003:
        problems.append(f"{len(ages)} sockets closed with {code!r}, not 4003")
    elif min(ages) < HELLO_DEADLINE_S - 0.5:
        problems.append(f"a socket was closed {min(ages):.1f} s after the upgrade, before the deadline")
if results[-1] is None or results[-1][1] != 4003:
    problems.append(f"a socket sending pings but no hello wasn't closed with 4003: {results[-1]}")

# The late hello was in time: the socket is a client like any other.
try:
    r = late.command("debug/memoryStats", timeout=5)
    assert r.get("success"), r
    late.drain(HELLO_DEADLINE_S / 2)
    assert late.command("debug/memoryStats", timeout=5).get("success")
    print(f"a hello {LATE_HELLO_AT_S} s after the upgrade was accepted and the socket kept")
except (AssertionError, OSError, TimeoutError, Closed) as e:
    problems.append(f"a socket whose hello came {LATE_HELLO_AT_S} s after the upgrade was dropped: {e!r}")
for c in silent:
    c.close()

# ── 2. HTTP requests that never finish ────────────────────────────────
time.sleep(1.0)
slow = []
for i in range(SLOTS):
    s = socket.create_connection((HOST, PORT), timeout=3)
    s.sendall(b"GET / HTTP/1.1\r\n")
    slow.append(s)
request = b"X-Slow: " + b"a" * 100
stop_trickle = threading.Event()


def trickle():
    i = 0
    while not stop_trickle.is_set():
        for s in slow:
            try:
                s.send(request[i % len(request):][:1])
            except OSError:
                pass
        i += 1
        time.sleep(0.5)


trickler = threading.Thread(target=trickle, daemon=True)
trickler.start()
started = time.time()
took = phone_gets_in(started)
stop_trickle.set()
trickler.join()
if took is None:
    problems.append(f"a phone was locked out for {GIVE_UP_S:.0f} s by {SLOTS} unfinished HTTP requests")
else:
    print(f"phone got in {took:.1f} s after {SLOTS} unfinished HTTP requests took the slots")
    if took > 12:
        problems.append(f"a phone got in only {took:.1f} s after unfinished requests took the slots")
for s in slow:
    s.close()

assert not problems, "\n".join(problems)
