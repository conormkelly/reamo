"""Operation tour: every protocol command, performed the way the UI sends it,
against a realistic project, with REAPER as the oracle.

For each operation the tour
  1. digests the project in REAPER (digest.lua: every user-visible fact),
  2. sends the command(s) exactly as the frontend builds them,
  3. waits until REAPER shows exactly the declared change and nothing else
     (a command that touches the wrong track, item or setting fails here),
  4. for undoable edits, undoes and redoes from the client and requires the
     project to return to the before/after state (the user can recover),
  5. requires every event stream the clients mirror to converge to REAPER's
     state (skeleton, tracks, items, markers, regions, transport, project),
  6. requires that REAPER is still alive.

Ops register the commands they cover; check_tour_coverage.py fails the run
when a registered command has no op (or reasoned exemption).
"""
import fnmatch
import json
import math
import sys
import time
import traceback

from reamo_client import Client, reaper, open_project, screenshot

OPS = []  # (name, commands covered, function)
EXEMPT = {}  # command -> reason it is not toured


def op(name, *commands):
    def register(fn):
        OPS.append((name, commands, fn))
        return fn
    return register


class Skip(Exception):
    """The project lacks what this op needs (e.g. no audio items)."""


class Mismatch(AssertionError):
    pass


# ----------------------------------------------------------------------------
# Digest helpers

def flatten(obj, prefix=""):
    out = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.update(flatten(v, f"{prefix}{k}."))
    elif isinstance(obj, list):
        if not obj:
            out[prefix[:-1] + "[]"] = 0
        for i, v in enumerate(obj):
            out.update(flatten(v, f"{prefix}{i}."))
    else:
        out[prefix[:-1]] = obj
    return out


VOLATILE = ("undo.*",)


def diff(before, after):
    keys = set(before) | set(after)
    return {k: (before.get(k, "<absent>"), after.get(k, "<absent>")) for k in keys
            if before.get(k, "<absent>") != after.get(k, "<absent>")
            and not any(fnmatch.fnmatchcase(k, v) for v in VOLATILE)}


ANY = object()  # path may change to anything


def approx(want, tol=1e-3):
    return lambda got: isinstance(got, (int, float)) and abs(got - want) <= tol


def matches(spec, got):
    if spec is ANY:
        return True
    if callable(spec):
        return spec(got)
    if isinstance(spec, float) and isinstance(got, (int, float)):
        return abs(spec - got) <= 1e-4
    return spec == got


# ----------------------------------------------------------------------------

class Tour:
    def __init__(self, project, user_flow_name):
        self.project = project
        self.name = user_flow_name
        self.results = []
        self.c = None  # the phone driving the session
        self.watcher = None  # a second client mirroring everything
        self.d = None  # current digest (raw)
        self.flat = None

    # -- REAPER side --------------------------------------------------------
    def digest(self):
        d = reaper("return dofile('/harness/digest.lua').digest()", timeout=10)
        # Lua cannot tell an empty map from an empty list; these are maps.
        for key in ("tracks", "items", "markers"):
            d[key] = d[key] or {}
        for tr in d["tracks"].values():
            for key in ("fx", "infx", "envs"):
                tr[key] = tr[key] or {}
        d["project"]["reamo"] = d["project"]["reamo"] or {}
        self.d = d
        self.flat = flatten(d)
        return self.flat

    def tracks(self):
        """User tracks in order: [(guid, track digest)]."""
        return sorted(((g, t) for g, t in self.d["tracks"].items() if g != "master"), key=lambda gt: gt[1]["pos"])

    def track(self, pred=None, name=None):
        for g, t in self.tracks():
            if (name is None or t["name"] == name) and (pred is None or pred(g, t)):
                return g, t
        raise Skip(f"no track {name or ''} matching the op's needs")

    def items(self, pred=None):
        out = [(g, it) for g, it in self.d["items"].items() if pred is None or pred(g, it)]
        return sorted(out, key=lambda gi: (self.d["tracks"][gi[1]["track"]]["pos"], gi[1]["idx"]))

    def item(self, pred=None):
        found = self.items(pred)
        if not found:
            raise Skip("no item matching the op's needs")
        return found[0]

    # -- client side --------------------------------------------------------
    def send(self, command, awaited=False, client=None, **params):
        """Send as the frontend does (every command carries an id). Returns
        the response, or None when the handler sends none. A command the UI
        awaits must respond."""
        c = client or self.c
        params = {k: v for k, v in params.items() if v is not None}
        try:
            r = c.command(command, timeout=5.0 if awaited else 1.0, **params)
        except TimeoutError:
            if awaited:
                raise Mismatch(f"{command} sent no response within 5 s; the UI awaits it")
            return None
        return r

    def ok(self, command, **params):
        """Send and require success (or no response at all)."""
        r = self.send(command, **params)
        if r is not None and not r.get("success", False):
            raise Mismatch(f"{command} failed: {r.get('error')}")
        return r

    def expect(self, changes=None, timeout=3.0, allow=()):
        """Wait until REAPER shows exactly `changes` (path pattern -> expected
        value, ANY, or predicate) relative to the digest taken before the op,
        with no other change except patterns in `allow`."""
        changes = changes or {}
        before = self.flat
        deadline = time.time() + timeout
        while True:
            after = self.digest()
            delta = diff(before, after)
            problems = self._check(delta, after, changes, allow)
            if not problems:
                return delta
            if time.time() > deadline:
                raise Mismatch("REAPER state after the op:\n    " + "\n    ".join(problems))
            self.c.drain(0.15)

    @staticmethod
    def _check(delta, after, changes, allow):
        problems = []
        for path, (old, new) in sorted(delta.items()):
            if not any(fnmatch.fnmatchcase(path, pat) for pat in list(changes) + list(allow)):
                problems.append(f"unexpected change {path}: {old!r} -> {new!r}")
        for pat, spec in changes.items():
            hits = [p for p in after if fnmatch.fnmatchcase(p, pat)]
            if spec is ANY:
                continue
            if not hits:
                problems.append(f"expected {pat} = {spec!r}, but it does not exist")
            for p in hits:
                if not matches(spec, after[p]):
                    problems.append(f"expected {p} = {spec if not callable(spec) else 'predicate'}, got {after[p]!r}")
        return problems

    def check_undo(self):
        """The whole op is one undo step: undo returns the project to how it
        was when the op started, redo to how it is now."""
        self.undo_redo(self.op_start, self.digest())

    def undo_redo(self, before_flat, after_flat):
        """Undo then redo from the client, as the UI's undo/redo buttons do,
        and require the project to return to exactly the before/after state."""
        r = self.send("undo/do", awaited=True)
        if not r.get("success"):
            raise Mismatch(f"undo/do failed: {r}")
        self._wait_equal(before_flat, "after undo/do, the project did not return to its state before the op")
        r = self.send("redo/do", awaited=True)
        if not r.get("success"):
            raise Mismatch(f"redo/do failed: {r}")
        self._wait_equal(after_flat, "after redo/do, the project did not return to its state after the op")

    def _wait_equal(self, target, what, timeout=3.0):
        deadline = time.time() + timeout
        while True:
            now = self.digest()
            delta = diff(target, now)
            if not delta:
                return
            if time.time() > deadline:
                lines = [f"{k}: {a!r} vs {b!r}" for k, (a, b) in sorted(delta.items())][:20]
                raise Mismatch(what + ":\n    " + "\n    ".join(lines))
            self.c.drain(0.15)

    # -- convergence: what clients show == what REAPER says -----------------
    def converge(self, timeout=3.0):
        deadline = time.time() + timeout
        while True:
            self.watcher.drain(0.2)
            self.c.drain(0.05)
            self.digest()
            problems = self._mirror_problems(self.watcher)
            if not problems:
                return
            if time.time() > deadline:
                raise Mismatch("clients disagree with REAPER:\n    " + "\n    ".join(problems[:25]))

    def _mirror_problems(self, c):
        from tour_mirror import mirror_problems
        return mirror_problems(self, c)

    # -- running -----------------------------------------------------------
    def run(self, only=None):
        with Client() as watcher, Client() as phone:
            self.watcher, self.c = watcher, phone
            for cl in (watcher, phone):
                cl.wait_event("trackSkeleton")
            # Open the user's project while both phones are connected, clicking
            # through the dialogs REAPER raises on the way, as the user would.
            dialogs = open_project(self.project)
            print(f"opened {self.project}; dialogs: {dialogs or 'none'}")
            self.digest()
            if self.d["project"]["play"] != 0:
                # Every op's diff would show the moving cursor; nothing after this is meaningful.
                raise Mismatch(f"transport is not stopped after opening the project (play state {self.d['project']['play']})")
            n = len(self.tracks())
            watcher.command("track/subscribe", range={"start": 0, "end": max(n, 1)}, includeMaster=True)
            self.converge(timeout=6.0)
            for name, commands, fn in OPS:
                if only and not any(o in name for o in only):
                    continue
                self._run_op(name, commands, fn)
                # Re-subscribe the watcher to every track (ops add and delete them).
                n = len(self.tracks())
                watcher.command("track/subscribe", range={"start": 0, "end": max(n, 1)}, includeMaster=True)
        return self.report()

    def _run_op(self, name, commands, fn):
        t0 = time.time()
        try:
            self.op_start = self.digest()
            fn(self)
            self.converge()
            if not reaper("return true"):
                raise Mismatch("REAPER stopped answering")
            status, detail = "PASS", ""
        except Skip as e:
            status, detail = "SKIP", str(e)
        except Mismatch as e:
            status, detail = "FAIL", str(e)
            screenshot(f"fail-{name.replace('/', '_')}")
        except Exception as e:  # a harness bug or a dead REAPER; keep going
            status, detail = "ERROR", f"{type(e).__name__}: {e}\n{traceback.format_exc(limit=3)}"
            screenshot(f"error-{name.replace('/', '_')}")
        self.results.append((name, commands, status, detail, time.time() - t0))
        print(f"{status:5} {name} ({time.time() - t0:.1f}s)" + (f"\n      {detail}" if detail and status != "PASS" else ""))
        sys.stdout.flush()

    def report(self):
        counts = {}
        for _, _, status, _, _ in self.results:
            counts[status] = counts.get(status, 0) + 1
        print(f"\ntour {self.name}: " + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())))
        return counts.get("FAIL", 0) == 0 and counts.get("ERROR", 0) == 0


def main(project, name, only=None):
    import tour_ops  # noqa: F401 registers the ops
    ok = Tour(project, name).run(only=only)
    sys.exit(0 if ok else 1)
