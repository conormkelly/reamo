# Context

**Reamo** — WebSocket-based remote control surface for REAPER (DAW), designed for iPad/tablet use while staying at your instrument.

**Architecture:**

- **Zig extension** runs inside REAPER, polls state at 3 tiers (HIGH 30Hz, MEDIUM 5Hz, LOW 1Hz), broadcasts JSON over WebSocket
- **React 19 + TypeScript frontend** receives events, sends commands back
- **Zustand** manages state, components subscribe to slices
- Extension uses comptime duck typing (`anytype`) for testability — `RealBackend` for production, `MockBackend` for tests

**Key constraint:** Never crash REAPER. Musicians may have unsaved work. All REAPER API values (especially floats) must be validated for NaN/Inf.

---

# Task

**Type:** [ ] Bug fix  [ ] Feature  [ ] Refactor  [ ] Architecture question  [ ] Investigation only

**Summary:**
[One sentence]

**Details:**
[Observed vs expected behavior, context, hypothesis if any]

**Scope:**
[ ] Investigate only — present findings, don't change code
[ ] Investigate → propose options → wait for my input
[ ] Investigate → fix it → run tests

---

# How I Want to Work

**Do:**

- Present options when architectural decisions are involved; just fix it for obvious bugs
- If something is ambiguous or you'd need to verify behavior empirically, **ask rather than guess**. I'd rather answer a question than debug a fix built on wrong assumptions.
- Run `make test` after changes; prompt me to run `make dev` for full frontend + extension rebuild cycle (do not run `make dev` yourself, it kills the REAPER process)

**Don't:**

- Plaster over symptoms — understand root cause first
- Skip reading existing code before proposing changes

---

# Reference

**Docs to read:**

| If working on... | Read first |
|------------------|------------|
| Any task | `DEVELOPMENT.md` — architecture, conventions, pitfalls |
| Extension/protocol | `extension/API.md` — WebSocket command/event reference |
| New features | `PLANNED_FEATURES.md` — roadmap and specs |
| REAPER C API | `docs/reaper_plugin_functions.h` — authoritative signatures. This one is very large so use grep tool on it. |

**Build commands:**

```bash
make test            # All tests (frontend + extension)
make frontend        # Build → reamo.html (auto-reloads on iPad)
make extension       # Build → REAPER UserPlugins (requires restart)
```

**Common gotchas:**

- Track index 0 = master in our "unified indexing", but raw REAPER API uses `GetMasterTrack()` separately
- Color value 0 means "no custom color" — check the 0x01000000 flag
- New command handlers must be added to `commands/registry.zig`
- New backend methods need both `RealBackend` and `MockBackend`
- Zig `@intFromFloat` panics on NaN/Inf — use `ffi.safeFloatToInt()`

**Testing WebSocket manually:**

```bash
curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken"  # Get token
# Then use websocat or extension/test-client.html
```
