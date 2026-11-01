"""Clients that vanish while REAmo is writing to them can't kill REAPER, even
when SIGPIPE is at its default action (terminate the process).

Linux REAPER installs a no-op SIGPIPE handler in main(), and REAmo installs
one where REAPER hasn't, but either can be replaced by anything else in the
process (another extension, a crash reporter). So the socket writes must not
raise SIGPIPE at all. This puts SIGPIPE back to SIG_DFL in the running REAPER
(gdb calls sigaction in it), then drops phones while REAmo writes to them:
audio listeners closing gracefully (websocket.zig answers with a close
frame), resetting, or resetting after they stop reading; and page loads and
malformed requests (httpz's own 400) dropped before their answer.
"""
import socket
import struct
import subprocess
import time

from reamo_client import Client, Closed, reaper, skip, skip_unless_linux

skip_unless_linux("sets REAPER's SIGPIPE disposition with gdb; Windows has no SIGPIPE")

SIGPIPE_BIT = 1 << (13 - 1)  # /proc/<pid>/status masks: bit n-1 is signal n
ROUNDS = 25


def reaper_pid():
    out = subprocess.run(["pgrep", "-x", "reaper"], capture_output=True, text=True).stdout.split()
    return out[0] if out else None


def sigpipe_masks(pid):
    masks = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            key, _, value = line.partition(":")
            if key in ("SigIgn", "SigCgt"):
                masks[key] = int(value.strip(), 16) & SIGPIPE_BIT != 0
    return masks


def tracer_pid(pid):
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("TracerPid:"):
                return int(line.split()[1])
    return 0


def set_sigpipe_default(pid):
    # A zeroed struct sigaction is SIG_DFL with an empty mask and no flags.
    out = subprocess.run(
        ["gdb", "-q", "-batch", "-p", pid,
         "-ex", "set $act = (char *) calloc(1, 256)",
         "-ex", "call (int) sigaction(13, $act, 0)"],
        capture_output=True, text=True, timeout=60)
    masks = sigpipe_masks(pid)
    assert masks == {"SigIgn": False, "SigCgt": False}, (
        f"could not put SIGPIPE back to SIG_DFL in REAPER: {masks}\n{out.stdout}\n{out.stderr}")


def reset_close(sock):
    """Close with an RST, as a phone dropping off Wi-Fi looks once it times out."""
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    sock.close()


def http_and_drop(request, rst):
    s = socket.create_connection(("127.0.0.1", 9224), timeout=5)
    s.sendall(request)
    if rst:
        reset_close(s)
    else:
        s.close()


def drop_listener(how):
    """A phone listening to audio (and receiving every broadcast) that vanishes."""
    c = Client()
    started = c.command("audio/startStream")["success"]
    if how == "stalled":
        time.sleep(0.3)  # stops reading: the server's writes back up
    else:
        c.drain(0.15)
    if how == "graceful":
        c.sock.shutdown(socket.SHUT_RDWR)
        c.close()
    else:
        reset_close(c.sock)
    return started


pid = reaper_pid()
if tracer_pid(pid) != 0:
    skip("REAPER is already under a debugger (HARNESS_GDB=1); this scenario attaches gdb itself")
set_sigpipe_default(pid)
print("SIGPIPE in REAPER is now SIG_DFL:", sigpipe_masks(pid))

reaper("reaper.OnPlayButton()")
problems = []
streams = 0
for r in range(ROUNDS):
    try:
        for how in ("graceful", "reset", "stalled"):
            streams += drop_listener(how)
        for rst in (False, True):
            http_and_drop(b"GET / HTTP/1.1\r\nHost: 127.0.0.1:9224\r\n\r\n", rst)
            # Malformed: httpz answers 400 itself, outside any REAmo handler.
            http_and_drop(b"TEA / HTTP/1.1\r\n\r\n", rst)
    except (OSError, Closed) as e:
        print(f"round {r + 1}: {e!r}")
    time.sleep(0.2)
    if reaper_pid() is None:
        problems.append(f"REAPER died in round {r + 1} of {ROUNDS}")
        break
print(f"rounds run: {r + 1}; audio streams started: {streams}")
if not problems:
    if streams == 0:
        problems.append("no audio stream ever started: the audio write path went untested")
    with Client() as c:
        if not c.command("debug/memoryStats")["success"]:
            problems.append("REAmo stopped answering after the drops")
    masks = sigpipe_masks(pid)
    if masks != {"SigIgn": False, "SigCgt": False}:
        problems.append(f"something re-installed a SIGPIPE disposition mid-test: {masks}")
assert not problems, "\n".join(problems)
