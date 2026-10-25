#!/usr/bin/env python3
"""Fail unless the operation tour covers every protocol command.

Every command in extension/src/commands/registry.zig needs an op in
tour_ops/ that performs it, or an EXEMPT entry saying why the tour leaves it
out. An op that names a command the registry doesn't have also fails, so a
renamed command can't leave a stale op claiming coverage.

    scripts/harness/check_tour_coverage.py
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import tour  # noqa: E402
import tour_ops  # noqa: E402,F401  registers the ops


def registry_commands():
    path = os.path.join(HERE, "..", "..", "extension", "src", "commands", "registry.zig")
    with open(path, encoding="utf-8") as f:
        return re.findall(r'^\s*\.\{\s*"([^"]+)"', f.read(), re.MULTILINE)


def main():
    registered = registry_commands()
    if not registered:
        sys.exit("check_tour_coverage: found no commands in registry.zig; has its format changed?")
    covered = {c for _, commands, _ in tour.OPS for c in commands}
    exempt = set(tour.EXEMPT)
    known = set(registered)

    missing = [c for c in registered if c not in covered and c not in exempt]
    stale = sorted((covered | exempt) - known)
    both = sorted(covered & exempt)

    for c in missing:
        print(f"not toured: {c}")
    for c in stale:
        print(f"not a registry command (renamed or removed?): {c}")
    for c in both:
        print(f"both toured and exempt: {c}")
    print(f"tour coverage: {len(known & covered)} toured, {len(known & exempt)} exempt, "
          f"{len(missing)} missing, of {len(known)} commands")
    sys.exit(1 if missing or stale or both else 0)


if __name__ == "__main__":
    main()
