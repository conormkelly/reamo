"""The tour's operations, one module per protocol area, run in the order a
session would plausibly use them.

Each op performs one user action with the parameters the frontend sends
(frontend/src/core/WebSocketCommands.ts) and declares exactly what REAPER
should show afterwards. See tour.py for what is checked around every op.
Importing this package registers every op.
"""
from . import transport, mixer  # noqa: F401
