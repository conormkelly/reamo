"""Clients that vanish while REAmo is writing to them can't kill REAPER, even
when SIGPIPE is at its default action (terminate the process).

Linux REAPER installs a no-op SIGPIPE handler in main(), and REAmo installs
one where REAPER hasn't, but either can be replaced by anything else in the
process (another extension, a crash reporter). So the socket writes must not
raise SIGPIPE at all. This puts SIGPIPE back to SIG_DFL in the running REAPER
(gdb calls sigaction in it), then drops clients while REAmo writes to them:

- audio listeners that close gracefully (websocket.zig answers with a close
  frame), reset, or reset after they stop reading: websocket.zig's sends;
- a 4 MiB download whose client closes as soon as it has asked for it:
  httpz's first send of the response succeeds (the client's system answers
  it with a reset) and is partial, and the next one fails with EPIPE, so
  HTTPConn.writeAllIOVec's sends are covered;
- page loads and malformed requests (httpz's own 400) dropped before their
  answer.

What this can't catch on Linux: a lost MSG_NOSIGNAL in httpz's single-send
paths (writeError, and a response small enough for one send). Linux raises
SIGPIPE only when a send fails with EPIPE: after the peer's reset, the
first failing send gets ECONNRESET, unless the peer had already closed its
end, and httpz stops at the first error. A single send to a peer that has
closed its end succeeds. macOS raises SIGPIPE on the first send after a
reset, so there those paths matter; httpz's unit tests cover them.
"""
import socket
import struct
import subprocess
import sys
import time

from reamo_client import REAPER_HOME, Client, Closed, reaper, skip, skip_unless_linux

skip_unless_linux("sets REAPER's SIGPIPE disposition with gdb; Windows has no SIGPIPE")

SIGPIPE_BIT = 1 << (13 - 1)  # /proc/<pid>/status masks: bit n-1 is signal n
ROUNDS = 25
HOST, PORT = "127.0.0.1", 9224


def fail(message):
    print(f"FAIL: {message}")
    sys.exit(1)


def reaper_pid():
    out = subprocess.run(["pgrep", "-x", "reaper"], capture_output=True, text=True).stdout.split()
    return out[0] if out else None


def proc_status(pid):
    with open(f"/proc/{pid}/status") as f:
        return dict(line.rstrip("\n").split(":\t", 1) for line in f if ":\t" in line)


def sigpipe_masks(pid):
    status = proc_status(pid)
    return {key: int(status[key], 16) & SIGPIPE_BIT != 0 for key in ("SigIgn", "SigCgt")}


def set_sigpipe_default(pid):
    # A zeroed struct sigaction is SIG_DFL with an empty mask and no flags.
    out = subprocess.run(
        ["gdb", "-q", "-batch", "-p", pid,
         "-ex", "set $act = (char *) calloc(1, 256)",
         "-ex", "call (int) sigaction(13, $act, 0)"],
        capture_output=True, text=True, timeout=60)
    if "ptrace: Operation not permitted" in out.stderr or "Could not attach" in out.stderr:
        fail("gdb couldn't attach to REAPER: the scenario's `capabilities` file must grant "
             f"SYS_PTRACE.\n{out.stderr[-1000:]}")
    masks = sigpipe_masks(pid)
    if masks != {"SigIgn": False, "SigCgt": False}:
        fail(f"gdb didn't put SIGPIPE back to SIG_DFL in REAPER: {masks}\n"
             f"{out.stdout[-1000:]}\n{out.stderr[-1000:]}")


def reset_close(sock):
    """Close with an RST, as a phone dropping off Wi-Fi looks once it times out."""
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    sock.close()


def http_and_drop(request, rst):
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.sendall(request)
    if rst:
        reset_close(s)
    else:
        s.close()


def large_download_closed_at_once(path):
    """Ask for a large file and close before any of it arrives."""
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.sendall(b"GET " + path + f" HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n\r\n".encode())
    s.close()


def drop_listener(how):
    """A phone listening to audio (and receiving every broadcast) that vanishes.
    Returns whether the stream started and how many audio frames arrived."""
    c = Client()
    started = c.command("audio/startStream")["success"]
    if how == "stalled":
        time.sleep(0.3)  # stops reading: the server's writes back up
    else:
        c.drain(0.15)
    frames = len(c.binary)
    if how == "graceful":
        c.sock.shutdown(socket.SHUT_RDWR)
        c.close()
    else:
        reset_close(c.sock)
    return started, frames


pid = reaper_pid()
if pid is None:
    fail("REAPER isn't running at the start of the scenario")
if int(proc_status(pid)["TracerPid"]) != 0:
    skip("REAPER is already under a debugger (HARNESS_GDB=1); this scenario attaches gdb itself")
# REAmo serves files up to exactly 4 MiB from its web folder (one byte more
# is FileTooBig, answered 404). One that size takes httpz more than one send
# on loopback.
LARGE_SIZE = 4 * 1024 * 1024
with open(f"{REAPER_HOME}/reaper_www_root/reamo/large-download.bin", "wb") as f:
    f.write(b"x" * LARGE_SIZE)
check = socket.create_connection((HOST, PORT), timeout=5)
check.sendall(f"GET /large-download.bin HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nConnection: close\r\n\r\n".encode())
head = b""
while b"\r\n\r\n" not in head:
    chunk = check.recv(65536)
    if not chunk:
        break
    head += chunk
check.close()
headers = head.split(b"\r\n\r\n", 1)[0]
if not headers.startswith(b"HTTP/1.1 200") or f"\r\nContent-Length: {LARGE_SIZE}".encode() not in headers:
    fail(f"the large download isn't served whole: {headers[:300]!r}")

set_sigpipe_default(pid)
print("SIGPIPE in REAPER is now SIG_DFL:", sigpipe_masks(pid))

reaper("reaper.OnPlayButton()")
problems = []
streams = frames = 0
for r in range(ROUNDS):
    try:
        for how in ("graceful", "reset", "stalled"):
            started, got = drop_listener(how)
            streams += started
            frames += got
        large_download_closed_at_once(b"/large-download.bin")
        for rst in (False, True):
            http_and_drop(f"GET / HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n\r\n".encode(), rst)
            # Malformed: httpz answers 400 itself, outside any REAmo handler.
            http_and_drop(b"TEA / HTTP/1.1\r\n\r\n", rst)
    except (OSError, Closed) as e:
        print(f"round {r + 1}: {e!r}")
    time.sleep(0.2)
    if reaper_pid() is None:
        problems.append(f"REAPER died in round {r + 1} of {ROUNDS}")
        break
print(f"rounds run: {r + 1}; audio streams started: {streams}; audio frames received: {frames}")
if not problems:
    if streams == 0 or frames == 0:
        problems.append(f"no audio reached the listeners ({streams} streams started, {frames} frames): "
                        "the audio write path went untested")
    with Client() as c:
        if not c.command("debug/memoryStats")["success"]:
            problems.append("REAmo stopped answering after the drops")
    masks = sigpipe_masks(pid)
    if masks != {"SigIgn": False, "SigCgt": False}:
        problems.append(f"something re-installed a SIGPIPE disposition mid-test: {masks}")
assert not problems, "\n".join(problems)
