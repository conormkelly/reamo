"""A first start with nothing saved logs no warnings.

A warning in a user's log should mean something went wrong. A fresh
install has no saved port or allowed hosts, which REAPER reports as an
empty value, and that is not a mistake to warn about.
"""
from reamo_client import Client, reaper

with Client(timeout=10) as c:
    c.wait_event("trackSkeleton")
    log = reaper("local f = io.open(reaper.GetResourcePath() .. '/Logs/reamo.log'); local s = f:read('a'); f:close(); return s")
    warnings = [line for line in log.splitlines() if " WARN " in line or " ERROR " in line]
    assert not warnings, "\n".join(warnings)
    print(f"{len(log.splitlines())} log lines, no warnings")
