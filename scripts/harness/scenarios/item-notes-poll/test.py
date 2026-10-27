"""A connected client starts item polling, which reads every item's notes."""
from reamo_client import Client

with Client() as c:
    c.drain(3)  # several medium-tier (5 Hz) polls
    print(f"ok: survived polling; items events={sum(1 for e, _ in c.events if e == 'items')}")
