"""A browser closing its connections is no error in REAmo's log.

Closing or reloading the app, or a phone going to sleep, has the browser
reset the connections it keeps open between requests. That is ordinary,
and a log that calls it a server error sends whoever reads a user's
report after nothing. On Windows each reset logged "server error".
"""
import socket
import struct
import time

from reamo_client import HOST, PORT, reaper


def log():
    return reaper("local f = io.open(reaper.GetResourcePath() .. '/Logs/reamo.log'); local s = f:read('a'); f:close(); return s")


before = len(log().splitlines())
for _ in range(3):
    s = socket.create_connection((HOST, PORT), timeout=5)
    s.sendall(b"GET /api/ping HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")  # kept alive
    assert s.recv(200).startswith(b"HTTP/1.1 200"), "no answer to the request"
    time.sleep(0.3)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))  # reset, as a closing tab does
    s.close()
time.sleep(1)
new = log().splitlines()[before:]
problems = [line for line in new if " ERROR " in line or " WARN " in line]
assert not problems, "\n".join(problems)
print("3 connections reset by the client; nothing logged as a problem")
