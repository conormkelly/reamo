"""A request whose bytes arrive in several pieces is answered.

Over Wi-Fi a request can arrive in more than one packet, some time apart.
The server waits up to its request timeout (5 s) for the rest; a pause of
a fraction of that must not lose the request.
"""
import socket
import time

from reamo_client import HOST, PORT, Client

with Client(timeout=10) as phone:
    phone.wait_event("trackSkeleton")
    for pause in (0.05, 0.3, 1.0):
        with socket.create_connection((HOST, PORT), timeout=5) as s:
            s.sendall(b"GET /api/ping HTTP/1.1\r\n")
            time.sleep(pause)
            s.sendall(b"Host: 127.0.0.1\r\nConnection: close\r\n\r\n")
            reply = b""
            try:
                while chunk := s.recv(4096):
                    reply += chunk
            except (socket.timeout, ConnectionResetError) as e:
                reply += f"<{type(e).__name__}>".encode()
        assert reply.startswith(b"HTTP/1.1 200"), f"after a {pause}s pause mid-request: {reply[:60]!r}"
    print("requests with 0.05, 0.3 and 1 s pauses answered")
