"""Stdlib-only WebSocket client for driving REAmo inside the harness container.

    from reamo_client import Client
    with Client() as c:                      # GET / for the token, upgrade, hello
        r = c.command("tempo/barsToTime", bar=2)   # waits for the matching response
        ev = c.wait_event("tracks")                # next event of that type

    from reamo_client import reaper
    reaper("reaper.SetCurrentBPM(0, 90, false)")   # act in REAPER itself, as a user would
    n = reaper("return reaper.CountTracks(0)")     # ...or ask it (REAPER as the oracle)
"""

import base64
import itertools
import json
import os
import re
import socket
import struct
import subprocess
import time
import urllib.request

HOST = "127.0.0.1"
PORT = int(os.environ.get("REAMO_PORT", "9224"))


def oracle():
    """Ground-truth values the fixture recorded with harness.oracle(), as strings."""
    try:
        with open("/tmp/harness_oracle.tsv", encoding="utf-8") as f:
            return dict(line.rstrip("\n").split("\t", 1) for line in f if "\t" in line)
    except FileNotFoundError:
        return {}


class ReaperError(Exception):
    """A reaper() chunk raised a Lua error."""


_rpc_ids = itertools.count(1)
RPC_DIR = "/tmp/harness_rpc"


class Pending:
    """An RPC chunk submitted to REAPER whose result has not been read yet."""

    def __init__(self, n):
        self.n = n
        self.out = f"{RPC_DIR}/{n}.out"

    def done(self):
        return os.path.exists(self.out)

    def result(self, timeout=5.0):
        deadline = time.time() + timeout
        while not self.done():
            if time.time() > deadline:
                raise TimeoutError(f"REAPER did not run rpc {self.n} within {timeout} s "
                                   f"(a modal dialog may be blocking it; windows: {windows()})")
            time.sleep(0.01)
        with open(self.out, "rb") as f:
            raw = f.read()
        try:
            res = json.loads(raw.decode("utf-8"))
        except UnicodeDecodeError as e:
            raise ReaperError(f"REAPER returned a string that is not valid UTF-8 "
                              f"(byte {e.start}: {raw[max(0, e.start - 40):e.start + 8]!r})") from None
        os.remove(self.out)
        if not res["ok"]:
            raise ReaperError(res["error"])
        vals = res["result"]
        return None if not vals else vals[0] if len(vals) == 1 else tuple(vals)


def submit(lua):
    """Queue a Lua chunk for REAPER's main thread without waiting for it."""
    n = next(_rpc_ids)
    req = f"{RPC_DIR}/{n}.lua"
    with open(req + ".tmp", "w", encoding="utf-8") as f:
        f.write(lua)
    os.rename(req + ".tmp", req)
    return Pending(n)


def reaper(lua, timeout=5.0):
    """Run a Lua chunk on REAPER's main thread (harness.lua serves these once
    the fixture calls harness.ready()) and return what it returns: None, one
    value, or a tuple. Chunks run in order, between extension timer ticks."""
    return submit(lua).result(timeout)


# Dialogs REAPER raises while loading an ordinary project, and the key a user
# would press to get past each.
LOAD_DIALOGS = {"Project Load Warning": "Return", "Missing media": "Return"}


def open_project(path, dialogs=LOAD_DIALOGS, timeout=30.0, on_dialog=None):
    """Open a project in REAPER as a user would, clicking through the dialogs
    REAPER shows on the way (each one is screenshotted first). Returns the
    titles of the dialogs that appeared. `on_dialog(title)` runs while a dialog
    blocks REAPER's main thread, before it is dismissed."""
    pending = submit(f'reaper.Main_openProject("noprompt:{path}")')
    seen = []
    deadline = time.time() + timeout
    while not pending.done():
        if time.time() > deadline:
            screenshot("open-project-timeout")
            raise TimeoutError(f"opening {path} did not finish; windows: {windows()}")
        for title in windows():
            for known, key in dialogs.items():
                if known.lower() in title.lower():
                    seen.append(title)
                    screenshot(f"dialog-{len(seen)}")
                    if on_dialog:
                        on_dialog(title)
                    press(title, key)
        time.sleep(0.1)
    pending.result()
    return seen


def screenshot(name):
    """Save REAPER's whole X display as out/<scenario>/<name>.png on the host."""
    path = os.path.join(os.environ.get("HARNESS_OUT", "/tmp"), f"{name}.png")
    subprocess.run(["import", "-window", "root", path], check=True, timeout=10)
    return path


def windows():
    """Titles of REAPER's visible windows: a dialog showing up here means a
    modal may be blocking REAPER's main thread."""
    r = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", ".", "getwindowname", "%@"],
                       capture_output=True, text=True, timeout=10)
    return [line for line in r.stdout.splitlines() if line]


def press(window_title, *keys):
    """Send keys (xdotool names, e.g. "Return", "Escape") to the first visible
    window whose title contains `window_title`, as a user dismissing a dialog."""
    r = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", window_title],
                       capture_output=True, text=True, timeout=10)
    ids = r.stdout.split()
    if not ids:
        raise LookupError(f"no visible window titled like {window_title!r}; windows: {windows()}")
    subprocess.run(["xdotool", "key", "--window", ids[0], *keys], check=True, timeout=10)


class Closed(Exception):
    """The server closed the connection."""


class InvalidFrame(Exception):
    """A text frame that is not valid UTF-8: a browser fails the connection
    on it (RFC 6455 8.1), so every client would disconnect."""


def fetch_token(host=HOST, port=PORT):
    html = urllib.request.urlopen(f"http://{host}:{port}/", timeout=5).read().decode()
    m = re.search(r'name="reamo-token" content="([0-9a-f]+)"', html)
    if not m:
        raise RuntimeError("no reamo-token in index.html")
    return m.group(1)


class Client:
    def __init__(self, host=HOST, port=PORT, hello=True, timeout=5.0):
        self.host, self.port, self.timeout = host, port, timeout
        self._ids = itertools.count(1)
        self._buf = b""
        self.events = []  # every event received, in order: (type, message)
        self.binary = []  # binary frames (peaks), raw bytes
        self._pending = []  # parsed text messages not yet consumed
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self._upgrade()
        if hello:
            self.send({"type": "hello", "token": fetch_token(host, port),
                       "protocolVersion": 1, "clientVersion": "harness"})

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _upgrade(self):
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            f"GET /ws HTTP/1.1\r\nHost: {self.host}:{self.port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode())
        while b"\r\n\r\n" not in self._buf:
            self._fill()
        head, self._buf = self._buf.split(b"\r\n\r\n", 1)
        if not head.startswith(b"HTTP/1.1 101"):
            raise RuntimeError(f"upgrade refused: {head[:80]!r}")

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise Closed("server closed the connection")
        self._buf += chunk

    def _need(self, n):
        while len(self._buf) < n:
            self._fill()

    def send(self, obj):
        data = json.dumps(obj).encode()
        n = len(data)
        hdr = bytearray([0x81])
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.sock.sendall(bytes(hdr) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _recv_frame(self):
        self._need(2)
        opcode, n = self._buf[0] & 0x0F, self._buf[1] & 0x7F
        off = 2
        if n == 126:
            self._need(4)
            n, off = struct.unpack(">H", self._buf[2:4])[0], 4
        elif n == 127:
            self._need(10)
            n, off = struct.unpack(">Q", self._buf[2:10])[0], 10
        self._need(off + n)
        payload, self._buf = self._buf[off:off + n], self._buf[off + n:]
        if opcode == 8:
            raise Closed(f"close frame {payload[:2].hex()} {payload[2:]!r}")
        return opcode, payload

    def _next_message(self, deadline):
        """Next text message; records events and binary frames as they pass."""
        while True:
            if self._pending:
                return self._pending.pop(0)
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError("no message before deadline")
            self.sock.settimeout(remaining)
            try:
                opcode, payload = self._recv_frame()
            except socket.timeout:
                raise TimeoutError("no message before deadline") from None
            if opcode == 2:
                self.binary.append(payload)
                continue
            if opcode != 1:
                continue
            try:
                text = payload.decode("utf-8")
            except UnicodeDecodeError as e:
                raise InvalidFrame(f"text frame is not valid UTF-8 at byte {e.start}: "
                                   f"{payload[max(0, e.start - 40):e.start + 8]!r}") from None
            msg = json.loads(text)
            if msg.get("type") == "event":
                self.events.append((msg.get("event"), msg))
            return msg

    def command(self, command, timeout=None, **params):
        """Send a command and return its response message."""
        cmd_id = f"h{next(self._ids)}"
        self.send({"type": "command", "command": command, "id": cmd_id, **params})
        deadline = time.time() + (timeout or self.timeout)
        while True:
            msg = self._next_message(deadline)
            if msg.get("type") == "response" and msg.get("id") == cmd_id:
                return msg

    def fire(self, command, **params):
        """Send a command without waiting for (or requesting) a response."""
        self.send({"type": "command", "command": command, **params})

    def wait_event(self, event, timeout=None):
        """Return the next event of this type (including ones already received)."""
        for i, (name, msg) in enumerate(self.events):
            if name == event:
                return self.events.pop(i)[1]
        deadline = time.time() + (timeout or self.timeout)
        while True:
            msg = self._next_message(deadline)
            if msg.get("type") == "event" and msg.get("event") == event:
                self.events.remove((event, msg))
                return msg

    def latest_event(self, event):
        """Most recent already-received event of this type, or None."""
        for name, msg in reversed(self.events):
            if name == event:
                return msg
        return None

    def drain(self, seconds):
        """Read everything for `seconds`; returns nothing, fills events/binary."""
        deadline = time.time() + seconds
        try:
            while True:
                self._next_message(deadline)
        except TimeoutError:
            pass
