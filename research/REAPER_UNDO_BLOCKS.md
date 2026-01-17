# REAPER's undo blocks don't nest and will corrupt with concurrent access

**REAPER does not support nested undo blocks**—calling `Undo_BeginBlock2()` twice before any `Undo_EndBlock2()` will corrupt the undo system state, not stack. For your WebSocket multi-client scenario, this is a critical design constraint requiring server-side serialization of all gesture operations.

The API takes a `ReaProject*` parameter for targeting specific projects, but undo blocks operate as **global state per project** without isolation between concurrent callers. When Client A starts a gesture and Client B starts another before A finishes, the second `BeginBlock` effectively hijacks or corrupts the first block's context. Cockos developer Justin Frankel explicitly warns: *"You must ALWAYS match your Undo_BeginBlock to your Undo_EndBlock—if you call Undo_BeginBlock and then never call Undo_EndBlock, you will really fudge the state of things up."*

## Nesting behavior is undefined and problematic

REAPER's undo block system uses a **single global state** rather than a stack. When `Undo_BeginBlock2()` is called, it suppresses all undo point creation until `Undo_EndBlock2()` is called. There is no reference counting or nesting depth tracking. Community developers have confirmed: nested `Undo_BeginBlock` calls interfere with each other, and the first block's description is typically lost.

The system exhibits these behaviors with concurrent/nested calls:

- **First block's context lost**: The second `BeginBlock` doesn't create a nested scope—it appears to reset or corrupt the pending block state
- **Undo history corruption**: Orphaned blocks (BeginBlock without matching EndBlock) cause "all kinds of weird behavior" including undo undoing everything or refusing to redo
- **No error signaling**: REAPER doesn't return errors or throw exceptions for mismatched calls—it silently corrupts state

Forum reports document users experiencing complete undo history corruption when scripts fail mid-block or when multiple scripts with undo blocks run concurrently. One developer noted: *"This kind of thing can happen if a ReaScript containing Undo_BeginBlock runs and doesn't reach the end block for whatever reason. When that happens, undo/redo goes completely wonky."*

## The project parameter provides targeting but not isolation

The `ReaProject* proj` parameter in `Undo_BeginBlock2()` allows targeting a specific project rather than the currently active one. However, official documentation explicitly warns: *"Do not switch project tabs from your code while in an Undo block."* This suggests the undo system has limitations when multiple projects are involved.

The parameter serves primarily to specify **which project's undo history receives the point**, not to create isolated concurrent undo contexts. Within a single project, there remains only one pending undo block state. Passing `NULL` operates on the active project, which is what SWS extension code consistently uses: `Undo_BeginBlock2(NULL)`.

## Deferred and concurrent operations are explicitly problematic

Community discussions reveal a fundamental architectural limitation. A developer explained the interleaving problem: *"Assume you have a deferred script running, creating an undopoint over its lifetime. During that time, other actions create undo points as well. Now you have the problem that the other undopoint is in 'the middle' of the defer undopoint... In which order do you want them to be undone? You have consistency issues."*

This directly applies to your WebSocket scenario. If Client A's gesture spans time while Client B initiates operations, the undo history becomes logically inconsistent. REAPER has no mechanism to handle interleaved undo blocks from multiple sources—it assumes single-threaded, sequential access to the undo system.

## Recommended patterns for your WebSocket architecture

Given these constraints, your multi-client remote control requires **server-side serialization** of undo block access. The SWS extension's approach reveals the standard pattern—direct procedural calls without concurrency protection, because native REAPER extensions assume they're the sole controller.

**Pattern 1: Global gesture mutex**
Implement a lock at your WebSocket server that ensures only one client can have an active gesture at a time. When Client B sends `gesture/start` while Client A's gesture is active, either queue B's gesture or reject it with an error.

```javascript
// Server-side pseudocode
let activeGesture = null;

function handleGestureStart(clientId, gestureData) {
  if (activeGesture !== null) {
    return { error: "Gesture in progress", activeClient: activeGesture.clientId };
  }
  activeGesture = { clientId, startTime: Date.now(), ...gestureData };
  reaper.Undo_BeginBlock2(null);
}

function handleGestureEnd(clientId, description) {
  if (activeGesture?.clientId !== clientId) {
    return { error: "No active gesture for this client" };
  }
  reaper.Undo_EndBlock2(null, description, -1);
  activeGesture = null;
}
```

**Pattern 2: Atomic operations without blocks**
For simple parameter changes, consider using `Undo_OnStateChangeEx2()` instead of Begin/End blocks. This creates individual undo points per operation, which is less elegant but avoids the nesting problem entirely. The SWS extension uses this pattern for single operations:

```c
Undo_OnStateChangeEx2(NULL, "Parameter change", UNDO_STATE_ALL, -1);
```

**Pattern 3: Gesture timeout with forced cleanup**
Implement gesture timeouts. If a client disconnects or fails to send `gesture/end` within a reasonable window, force-close the undo block to prevent corruption:

```javascript
const GESTURE_TIMEOUT_MS = 30000;

function startGestureTimeout(clientId) {
  setTimeout(() => {
    if (activeGesture?.clientId === clientId) {
      reaper.Undo_EndBlock2(null, "Cancelled gesture", -1);
      activeGesture = null;
    }
  }, GESTURE_TIMEOUT_MS);
}
```

**Pattern 4: PreventUIRefresh pairing**
SWS code consistently pairs undo blocks with UI refresh suppression. This prevents visual flickering during multi-step operations:

```c
PreventUIRefresh(1);
Undo_BeginBlock2(NULL);
// ... operations ...
Undo_EndBlock2(NULL, "Description", UNDO_STATE_ALL);
PreventUIRefresh(-1);
```

## Additional caveats from production code

The SWS extension reveals several additional best practices. Always check preconditions **before** starting an undo block to avoid empty undo points—their code pattern is to return early if there's nothing to do, then start the block only when work will definitely occur.

Some REAPER API functions reportedly create undo points **outside** undo blocks due to bugs. `TrackFX_SetPreset()` is documented as problematic. For MIDI operations, you may need to call `MarkTrackItemsDirty()` or perform a dummy selection change to ensure the undo point captures all changes.

The `extraflags` parameter matters significantly. Use `-1` (UNDO_STATE_ALL) when directly modifying project state to capture all changes. Use `0` only when calling other actions that create their own undo points. Using specific flags like `UNDO_STATE_ITEMS` may fail to create undo points if MIDI-related functions don't properly mark items dirty.

## Conclusion

Your WebSocket multi-client architecture faces a fundamental impedance mismatch with REAPER's undo system design. The undo block API assumes a single sequential caller and provides no isolation, stacking, or concurrent access support. **Implementing mutex-based gesture serialization at your server layer is mandatory**—there is no safe way to have overlapping undo blocks from multiple clients.

Consider whether your gesture system truly needs undo blocks at all. If individual parameter changes are acceptable as separate undo points, `Undo_OnStateChangeEx2()` provides a simpler, safer approach. Reserve Begin/End blocks for true multi-step operations where you control serialization completely. For robustness, implement gesture timeouts and forced cleanup to prevent orphaned blocks from corrupting the undo system when clients disconnect unexpectedly.
