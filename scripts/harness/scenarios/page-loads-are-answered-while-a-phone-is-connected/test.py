"""With a phone connected, every new connection is still answered.

A connected client's WebSocket stays open for its whole session. Page
loads, refreshes and other devices connect meanwhile, each on a fresh
connection, and every one must be answered promptly, not only those that
happen not to queue behind the phone's.
"""
import socket
import time

from reamo_client import HOST, PORT, Client

with Client(timeout=10) as phone:
    phone.wait_event("trackSkeleton")
    slow = []
    for i in range(24):
        start = time.time()
        with socket.create_connection((HOST, PORT), timeout=3) as s:
            s.sendall(b"GET /api/ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            reply = b""
            try:
                while chunk := s.recv(4096):
                    reply += chunk
            except socket.timeout:
                pass
        took = time.time() - start
        if not reply.startswith(b"HTTP/1.1 200") or took > 2:
            slow.append(f"connection {i}: {took:.1f}s, {reply[:40]!r}")
    assert not slow, f"{len(slow)} of 24 connections went unanswered with a phone connected:\n" + "\n".join(slow)
    assert phone.command("debug/memoryStats")["success"]
    print("24 connections answered with a phone connected")
