# Backend Plan Template

This template describes how to create and use `*_BACKEND_PLAN.md` documents for implementing new backend features. These documents serve as **living plans** that guide implementation and preserve context across sessions.

---

## Why This Pattern Works

1. **Context Bootstrapping** — New sessions read the plan first, not the full codebase
2. **Phased Execution** — Small, testable steps prevent scope creep and catch errors early
3. **Decision Memory** — Design rationale survives context window eviction
4. **Progress Persistence** — Progress log shows exactly where we left off
5. **Testing Checkpoints** — Explicit pauses to verify before moving forward

---

## How to Use

### Creating a New Plan

1. Copy the template below into `FEATURENAME_BACKEND_PLAN.md`
2. Fill in Quick Context (files to read, key concepts)
3. Define Scope (commands, state fields, REAPER APIs)
4. Document Design Decisions (with rationale)
5. Break into Implementation Phases (one concern per phase)
6. Define JSON output format and command signatures

### During Implementation

1. **Start each session** by reading the plan document
2. **Work one phase at a time** — complete fully before moving to next
3. **Build after each phase** — catch errors immediately
4. **Update checkboxes** as you complete items
5. **Add to Notes & Gotchas** when you discover quirks
6. **Update Progress Log** with dated entries

### Testing Checkpoints

Pause for manual testing after:
- All C bindings added (Phase 1-2)
- State polling working (can see data in events)
- Commands functional (WebSocket test)
- Full integration (end-to-end)

### Completing

1. Mark status as ✅ COMPLETE
2. Update `PLANNED_FEATURES.md` to mark backend done
3. Update `API.md` with protocol documentation
4. Keep the plan file — it's historical documentation

---

## Template

```markdown
# [Feature Name] — Backend Implementation Plan

**Status:** 🚧 IN PROGRESS | ✅ COMPLETE
**Last Updated:** YYYY-MM-DD

This is a living document tracking the [Feature Name] backend implementation. Update after completing each phase.

---

## Quick Context for New Sessions

**Read these files first:**
- `DEVELOPMENT.md` — Architecture, conventions, FFI validation layer pattern
- `extension/API.md` — Protocol format, existing events
- `features/FEATURENAME_FEATURE.md` — Full feature spec with UI concepts
- `SIMILAR_BACKEND_PLAN.md` — Similar implementation pattern (if applicable)

**Key architecture concepts:**
- `raw.zig` — Pure C bindings, returns what REAPER returns
- `RealBackend` — Adds validation via `ffi.safeFloatToInt()`
- `MockBackend` — Injectable state for testing
- `backend.zig` — `validateBackend(T)` ensures both backends have all methods
- [Add feature-specific concepts here]

---

## Testing with WebSocket

Get token and port, then connect:

\`\`\`bash
# Get credentials
TOKEN=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/SessionToken" | awk '{print $4}')
PORT=$(curl -s "http://localhost:8099/_/GET/EXTSTATE/Reamo/WebsocketPort" | awk '{print $4}')
echo "Token: $TOKEN, Port: $PORT"

# Connect and send commands
/bin/bash -c '{ echo '"'"'{"type":"hello","clientVersion":"1.0.0","protocolVersion":1,"token":"'$TOKEN'"}'"'"'; sleep 0.1; echo '"'"'{"type":"command","command":"your/command","param":"value","id":"1"}'"'"'; sleep 0.3; } | /opt/homebrew/bin/websocat ws://localhost:'$PORT' 2>&1 | head -20'
\`\`\`

---

## Scope & Features

| Command | Purpose | REAPER API |
|---------|---------|------------|
| `namespace/action` | What it does | `ReaperFunction()` |

| State Field | Purpose | REAPER API |
|-------------|---------|------------|
| `fieldName` | What it represents | `ReaperFunction()` |

---

## Design Decisions

### [Decision Title]

[Explain the decision and why this approach was chosen over alternatives]

**Rationale:**
- Point 1
- Point 2

### [Another Decision]

[Continue for each significant design choice]

---

## C API Functions

From `reaper_plugin_functions.h`:

\`\`\`c
// Description
ReturnType FunctionName(params);
// Notes about usage
\`\`\`

---

## Implementation Phases

### Phase 1: raw.zig — C Function Pointers
- [ ] Add `FunctionName` function pointer + wrapper
- [ ] Load in `Api.load()`

**Files:** `extension/src/reaper/raw.zig`

### Phase 2: real.zig — RealBackend Methods
- [ ] Add `methodName()` delegation

**Files:** `extension/src/reaper/real.zig`

### Phase 3: mock/ — MockBackend Support
- [ ] Add mock methods
- [ ] Add to `state.zig` Method enum
- [ ] Re-export in `mod.zig`

**Files:** `extension/src/reaper/mock/mod.zig`, `mock/state.zig`

### Phase 4: backend.zig — Update Validator
- [ ] Add new methods to `required_methods`

**Files:** `extension/src/reaper/backend.zig`

### Phase 5: State Module — Add Polling (if applicable)
- [ ] Add fields to state struct
- [ ] Implement `eql()` comparison
- [ ] Add polling logic
- [ ] Update `toJson()` serialization

**Files:** `extension/src/[module].zig`

### Phase 6: Commands — Add Handlers
- [ ] Create `commands/[module].zig` or add to existing
- [ ] Implement command handlers
- [ ] Register in `registry.zig`

**Files:** `extension/src/commands/[module].zig`, `commands/registry.zig`

### Phase 7: Documentation
- [ ] Update `API.md` — events and commands
- [ ] Update `PLANNED_FEATURES.md` — mark backend done
- [ ] Update this plan document

**Files:** `extension/API.md`, `PLANNED_FEATURES.md`

---

## JSON Output Format

[Show example JSON for events and responses]

\`\`\`json
{
  "type": "event",
  "event": "eventName",
  "payload": {
    "field": "value"
  }
}
\`\`\`

---

## Commands

| Command | Parameters | Response |
|---------|------------|----------|
| `namespace/action` | `param1`, `param2` | `{success: true, ...}` |

---

## Progress Log

| Date | Phase | Notes |
|------|-------|-------|
| YYYY-MM-DD | Phase 0 | Planning complete, document created |

---

## Notes & Gotchas

- [Quirk discovered during implementation]
- [Edge case to remember]
- [API behavior that wasn't obvious]
```

---

## Tips for Effective Plans

### Scope Definition
- List ALL commands and state fields upfront
- Include REAPER API function for each
- This prevents scope creep mid-implementation

### Phase Granularity
- One logical concern per phase
- Each phase should build successfully
- Test after phases 1-2, 5, 6

### Design Decisions
- Document the WHY, not just the WHAT
- Include alternatives considered
- Future readers will thank you

### Progress Log
- Date every entry
- Note blockers or discoveries
- Helps resume after long breaks

### Notes & Gotchas
- Add as you discover them
- These become invaluable for debugging
- Include specific values (action IDs, limits, etc.)

---

## Example Plans

- `TRACK_MANAGEMENT_BACKEND_PLAN.md` — Commands + state field
- `SEND_BACKEND_PLAN.md` — Nested state in tracks event + commands
- `FX_BACKEND_PLAN.md` — Tiered polling + commands

Each follows the same structure, proving the pattern scales.
