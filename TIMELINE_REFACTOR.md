# Timeline.tsx Decomposition Plan

## Problem Statement

`Timeline.tsx` is 1298 lines, has 49 commits of churn, 20 imports, and a 240-line `handlePointerUp` with 23 useCallback dependencies. It is the highest technical debt hotspot on the frontend. Every new feature touching the timeline risks regressions because unrelated concerns are entangled in a single function body.

The rendering layer is already well-decomposed (TimelineRuler, TimelineRegionBlocks, MultiTrackLanes, etc.). The problem is the **~1000 lines of orchestration** — store selectors, derived state, viewport logic, gesture routing, and item hit-testing — all living in one flat function scope.

## Safety Net

- **986 lines of integration tests** in `Timeline.test.tsx` covering: region display, selection, move/resize/delete/create, playhead positioning, time selection display, overflow prevention, viewport coordinates, and label LOD.
- **Gesture hook unit tests**: usePanGesture, usePinchGesture, useEdgeScroll, snapUtils each have dedicated test files.
- **Playwright E2E tests**: `timeline.spec.ts` (16), `timeline-viewport.spec.ts` (16), `marker-item-selection.spec.ts` (23) — 55/55 green. These are the real safety net for gesture/pointer behavior (Phases 3 and 4).

### Coverage gaps to be aware of

- **Zero Vitest coverage for pointer events.** No unit test fires `pointerDown`/`pointerMove`/`pointerUp` on the timeline canvas. All gesture testing lives in Playwright E2E or individual hook unit tests.
- **Follow-playhead animation untested at Vitest level.** The `useTransportAnimation` mock fires synchronously once; it does not simulate ongoing playback, threshold-based scrolling, or jump detection.
- **`sendCommand` was undefined in all Vitest tests.** Fixed — `useReaper` mock now provides `sendCommand: vi.fn()`.
- **Navigate mode never tested.** All Vitest tests use the default `'regions'` mode via `setupStore`.

## Constraints

- No behavior changes. Every phase is a mechanical extraction.
- No new dependencies or patterns. Stay within existing React hooks + Zustand conventions.
- Each phase is independently shippable. If we stop after any phase, the codebase is still better off.
- Preserve the existing test file structure. Tests import `Timeline` and interact with the store — extracted hooks should not require test rewrites.

## Decisions (resolved from review)

### `containerRef` stays in Timeline (Option B)

`containerRef` is used by 8+ consumers: viewport, pan gesture, pinch gesture, playhead drag, region drag, marker drag, edge scroll, item tap handler, pointer events, the ResizeObserver, and the JSX element. Putting it in the viewport hook would create unnecessary coupling — every future hook that needs the ref would have to route through viewport. Option B is more explicit (one extra parameter to the viewport hook) but avoids ownership confusion. The ref is fundamentally a DOM concern of the Timeline component, not a viewport concern.

### `renderTimeToPercent` cannot move into the viewport hook

It depends on `isRegionDragCancelled` from `useRegionDrag`, which itself depends on `containerRef`/`positionToTime` from the viewport hook. This creates a circular dependency. It must stay inline in Timeline or become its own trivial hook called after `useRegionDrag`. Evaluate after Phases 1-4.

### Edge-scroll wrappers stay in Timeline

The edge-scroll wrapper callbacks (lines 956-989) combine playhead/marker drag handlers with edge scroll. They are rendering-layer wiring, not pointer events on the canvas. They belong in the orchestration layer. Only ~35 lines.

### Derived region state block stays inline

The `displayRegions`/`dragPreview` block (~60 lines) is tightly coupled to region editing store state. The `useEffect` syncing `insertionPoint`/`resizeEdgePosition` back to the store is a subtle side effect easier to audit in the main component body. Not worth extracting at ~60 lines. Revisit after Phases 1-4 if Timeline is still too long.

### Pre-existing `viewport` object instability (documented, not fixed)

`useViewport()` returns a new object literal every render (lines 252-266 of useViewport.ts). Every `useCallback` that lists `viewport` in its deps already re-creates every render. This refactor does not worsen it, but implementers should be aware. Stabilizing the `useViewport` return later (e.g., via `useMemo`) would cascade benefits through all phases. Out of scope for this refactor.

---

## Pre-Refactor Checklist

Do ALL of these before touching Timeline.tsx:

### Must-have

- [x] **Fix `useReaper` mock** in Timeline.test.tsx line 40: add `sendCommand: vi.fn()` alongside `send: vi.fn()`. Pre-existing bug that blocks writing any new safety tests.
- [x] **Fix fragile playhead selectors** at test lines 431, 449, 465: change `.absolute.top-0.bottom-0` to `[data-testid="playhead"]`. Prevents DOM reordering from breaking tests during extraction.
- [x] **Fix `platform.ts` matchMedia crash**: `isPWA` evaluated `window.matchMedia()` at module load before jsdom mock was applied. Added `typeof window.matchMedia === 'function'` guard.
- [x] **Fix pre-existing assertion bugs**: `regions spanning beyond viewport` expected >100% width (impossible); `playhead position` expected viewport-relative 50% but playhead uses full-timeline `renderTimeToPercent` (~12%).
- [x] **Write viewport bounds snapshot test**: render Timeline with `songStructure()`, assert `data-visible-duration` on `[data-testid="timeline-canvas"]`. Catches memoization boundary shifts in Phase 2.
- [x] **Run full Vitest suite** — 925/925 green.
- [x] **Fix and run full Playwright E2E suite** — 55/55 green across all 3 timeline spec files. This is the real safety net for Phases 3 and 4.

### Should-have

- [ ] **Write navigate mode render test**: render Timeline with `setupStore(songStructure(), 'navigate')` and verify footer controls render. Currently all tests use `'regions'` mode.
- [ ] **Write one pointer event integration test** using the existing `gestures.ts` helpers (in `src/test/gestures.ts` — exists but unused): horizontal drag in selection mode, assert `useReaperStore.getState().timeSelection` is updated.
- [ ] **Unit test `getTrackIdxFromGuid`** as a pure function with a mock `trackSkeleton` array before it moves in Phase 3.

---

## Per-Phase Verification Protocol

Every phase must pass ALL of these before being considered complete:

1. `npx tsc --noEmit` — type check catches interface mismatches Vitest won't
2. `npx vitest run` — unit/integration tests
3. Playwright E2E suite — gesture coverage (especially for Phases 3 and 4)
4. Manual touch verification on real device/simulator (specific gestures listed per phase)
5. **Each phase = one atomic commit.** Never split across commits. This ensures `git revert` is always a clean rollback.

---

## Execution Order

Phases are ordered by risk (lowest first) and dependency (each phase's dependencies are complete before it starts).

| Order | Phase | New file | Lines moved | Depends on |
|-------|-------|----------|------------:|------------|
| 1st | Phase 1 (selectors) | `hooks/useTimelineSelectors.ts` | ~60 | Nothing |
| 2nd | Phase 3 (item tap) | `hooks/useItemTapHandler.ts` | ~130 | Phase 1 (for selector values) |
| 3rd | Phase 2 (viewport) | `hooks/useTimelineViewport.ts` | ~130 | Phase 1 |
| 4th | Phase 4 (pointer events) | `hooks/useTimelinePointerEvents.ts` | ~350 | Phases 1, 2, 3 |
| Defer | Phase 5 (renderTimeToPercent) | (evaluate) | ~40 | Phases 1-4 |

**Why Phase 3 before Phase 2:** Phase 3 extracts a self-contained block from within `handlePointerUp` — it's a pure function-like extraction with clear inputs/outputs and no cross-cutting state management. Phase 2 involves moving `containerRef` ownership decisions, `useTransportAnimation`, and the follow-playhead animation loop — all with subtler timing dependencies. Doing Phase 3 first proves the callback extraction pattern works before tackling the more stateful Phase 2.

**Dependency graph:**

```
Phase 1 (selectors) ─────┬──→ Phase 3 (item tap)
                          │           │
                          └──→ Phase 2 (viewport)
                                      │
                          ┌───────────┘
                          ▼
                    Phase 4 (pointer events) ←── Phase 3
```

Total: ~710 lines extracted, Timeline.tsx drops to ~350-400 lines.

---

## Phase 1: `useTimelineSelectors()` — Store selector consolidation

**Risk: Minimal | Impact: Readability**

### What moves

Lines 72-131 of Timeline.tsx — the 30+ individual `useReaperStore()` calls. Also scattered selectors at other locations:

- Lines 226-227: `openMarkerEditModal`, `openMakeSelectionModal`
- Lines 285-286: `selectionModeActive`, `toggleSelectionMode`
- Lines 291-293: `followPlayhead`, `setFollowPlayhead`, `pauseFollowPlayhead`
- Line 896: `setMarkerLocked`

**Note:** `useTransport()` (line 73) is NOT a `useReaperStore` call — it is a separate hook. It must either be called inside `useTimelineSelectors` explicitly or kept as a separate call in Timeline. Recommend: include it in the hook since `positionSeconds` is part of the selectors interface.

### Target file

`frontend/src/components/Timeline/hooks/useTimelineSelectors.ts`

### Interface

```ts
interface TimelineSelectors {
  // Transport & project data
  positionSeconds: number;
  regions: WSRegion[];
  markers: WSMarker[];
  items: WSItem[];
  trackSkeleton: SkeletonTrack[];
  bpm: number | null;
  tempoMarkers: TempoMarker[];
  storedTimeSelection: TimeSelection | null;
  setStoredTimeSelection: (ts: TimeSelection | null) => void;

  // Region editing
  timelineMode: TimelineMode;
  selectedRegionIds: number[];
  pendingChanges: PendingChanges;
  hasPendingChanges: boolean;
  selectRegion: (id: number) => void;
  deselectRegion: (id: number) => void;
  clearSelection: () => void;
  isRegionSelected: (id: number) => boolean;
  resizeRegion: (...) => void;
  moveRegion: (...) => void;
  startDrag: (...) => void;
  updateDrag: (...) => void;
  endDrag: (...) => void;
  cancelDrag: (...) => void;
  regionDragType: DragType;
  regionDragId: number | null;
  dragCurrentTime: number | null;
  dragStartTime: number | null;
  insertionPoint: number | null;
  resizeEdgePosition: number | null;

  // Item selection
  viewFilterTrackGuid: string | null;
  itemSelectionModeActive: boolean;
  enterItemSelectionMode: (guid: string) => void;
  setViewFilterTrack: (guid: string | null) => void;
  setSelectedMarkerId: (id: number | null) => void;

  // UI state
  selectionModeActive: boolean;
  toggleSelectionMode: () => void;
  followPlayhead: boolean;
  setFollowPlayhead: (v: boolean) => void;
  pauseFollowPlayhead: () => void;
  openMarkerEditModal: (...) => void;
  openMakeSelectionModal: () => void;
  setMarkerLocked: (v: boolean) => void;
}
```

### Procedure

1. Create the hook file with all `useReaperStore` calls and `useTransport()`.
2. In Timeline.tsx, replace the ~60 lines with `const s = useTimelineSelectors()`.
3. Find-replace all bare references (e.g. `regions` -> `s.regions`) OR destructure at call site.
4. Run verification protocol.

### Critical implementation notes

- **MUST keep individual `useReaperStore` calls.** Do NOT combine into `useReaperStore(s => ({ regions: s.regions, markers: s.markers, ... }))`. Zustand uses referential equality by default — a combined selector creates a new object on every store update, causing re-renders on every WebSocket message.
- **Gather ALL scattered selectors.** The selectors are not contiguous in the source. Lines 226-227, 285-286, 291-293, and 896 have additional selectors that must also move.
- **`getTrackIdxFromGuid` (lines 122-128) stays in Timeline for now.** It moves in Phase 3. Don't include it in Phase 1.

### Why this is safe

Pure mechanical extraction. Every selector returns the same value. No logic changes. Full Vitest coverage.

### Manual verification

None required — Vitest provides complete coverage for this phase.

### Rollback

```
git revert <commit>
```

Or manually: restore `Timeline.tsx`, delete `useTimelineSelectors.ts`, revert `hooks/index.ts`.

---

## Phase 3: `useItemTapHandler()` — Item hit-testing extraction

**Risk: Moderate | Impact: High**

> Note: Executed SECOND despite being numbered Phase 3. See Execution Order above.

This is the highest-value extraction. The multi-track lane hit-testing (lines 689-816 inside `handlePointerUp`) is a self-contained 130-line block with clear inputs and outputs.

### What moves

The item tap detection logic currently inlined in `handlePointerUp`:

- Multi-track lane index calculation
- Item filtering by track and time position
- Track selection commands
- Item selection mode entry
- Single-track mode fallback logic
- `getTrackIdxFromGuid` helper (lines 122-128) — only used here

### Target file

`frontend/src/components/Timeline/hooks/useItemTapHandler.ts`

### Interface

```ts
interface UseItemTapHandlerParams {
  containerRef: RefObject<HTMLDivElement>;
  viewport: UseViewportReturn;
  items: WSItem[];               // Full items array, NOT visibleItems
  trackSkeleton: SkeletonTrack[];
  multiTrackLanes?: SkeletonTrack[];
  multiTrackIndices?: number[];
  viewFilterTrackGuid: string | null;
  itemSelectionModeActive: boolean;
  enterItemSelectionMode: (guid: string) => void;
  setViewFilterTrack: (guid: string | null) => void;
  setSelectedMarkerId: (id: number | null) => void;
  sendCommand: (cmd: string) => void;
}

// Returns a function to call on tap with (clientX, clientY)
// Returns true if tap was handled (hit an item or lane), false otherwise
type ItemTapHandler = (clientX: number, clientY: number) => boolean;
```

### Procedure

1. Create the hook. Implement as a `useCallback` returning the handler function.
2. In `handlePointerUp`, replace the 130-line block with:

   ```ts
   if (dx < TAP_THRESHOLD && dy < TAP_THRESHOLD) {
     handleItemTap(e.clientX, e.clientY);
   }
   panStartPositionRef.current = null;
   return;
   ```

3. Move `getTrackIdxFromGuid` into the hook (it's only used here).
4. Run verification protocol.

### Critical implementation notes

- **`panStartPositionRef` clearing is the caller's job.** The current code has 5 flows through the item tap block, all ending with `panStartPositionRef.current = null; return;`. After extraction, the handler cannot `return` from the calling function. The replacement code (step 2 above) unconditionally nulls the ref after calling the handler — this preserves the behavior exactly. The handler should NOT touch `panStartPositionRef`.
- **Must receive full `items` array, not `visibleItems`.** The handler does its own time-based filtering using `viewport.visibleRange`. Passing viewport-filtered items would miss items at viewport edges.
- **12 dependency array entries migrate.** The current `handlePointerUp` dep array includes `items`, `setSelectedMarkerId`, `viewport`, `trackSkeleton`, `itemSelectionModeActive`, `enterItemSelectionMode`, `setViewFilterTrack`, `viewFilterTrackGuid`, `getTrackIdxFromGuid`, `sendCommand`, `multiTrackLanes`, `multiTrackIndices`. After extraction, all are replaced by the single `handleItemTap` reference in `handlePointerUp`'s deps. Missing any one creates a stale closure with no Vitest test to catch it.

### Why this is moderate risk

The extraction boundary is clean, but there are zero Vitest-level tests for this code path. All testing is via Playwright E2E. A stale closure or wrong parameter would not be caught until E2E or manual testing.

### Manual verification

- Tap an item in multi-track view → confirms item selects
- Tap empty lane space → confirms track selection
- Tap in single-track mode → confirms item selection mode entry
- Verify mutual exclusion between marker and item selection

### Rollback

```
git revert <commit>
```

Or manually: restore `Timeline.tsx`, delete `useItemTapHandler.ts`, revert `hooks/index.ts`.

---

## Phase 2: `useTimelineViewport()` — Viewport & follow-playhead

**Risk: Low-Moderate | Impact: Moderate**

> Note: Executed THIRD despite being numbered Phase 2. See Execution Order above.

### What moves

Lines 240-370 of Timeline.tsx:

- `maxPlayheadPosition` state + setter
- `baseTimelineStart` / `baseDuration` memo (timeline bounds calculation)
- `timelineStart` / `duration` aliases
- Internal viewport creation (`useViewport`) + external viewport merge
- Follow-playhead animation (`useTransportAnimation` block)
- `pauseFollow` alias
- `timeToPercent` callback
- `viewportTimeToPercent` callback
- `playheadPercent` derived value
- `positionToTime` callback
- `containerWidth` state + ResizeObserver (lines 200-223) — moves with containerRef since it observes the same element
- `usePanGesture` and `usePinchGesture` calls — they use `containerRef` and `viewport`

**Does NOT move:** `containerRef` (stays in Timeline per Option B decision), `usePlayheadDrag`, `useRegionDrag`.

### Target file

`frontend/src/components/Timeline/hooks/useTimelineViewport.ts`

### Interface

```ts
interface UseTimelineViewportParams {
  containerRef: RefObject<HTMLDivElement>;  // Passed IN from Timeline (Option B)
  positionSeconds: number;
  displayRegions: WSRegion[];
  markers: WSMarker[];
  items: WSItem[];
  externalViewport?: UseViewportReturn;
  followPlayhead: boolean;
  setFollowPlayhead: (v: boolean) => void;
  pauseFollowPlayhead: () => void;
  prefersReducedMotion: boolean;
}

interface UseTimelineViewportReturn {
  viewport: UseViewportReturn;
  containerWidth: number;
  timelineStart: number;
  duration: number;
  baseTimelineStart: number;
  baseDuration: number;
  timeToPercent: (time: number) => number;
  viewportTimeToPercent: (time: number) => number;
  playheadPercent: number;
  positionToTime: (clientX: number) => number;
  pauseFollow: () => void;
  panGesture: PanGestureReturn;
  pinchGesture: PinchGestureReturn;
}
```

### Dependency note

`containerRef` is passed IN from Timeline (Option B). The hook uses it for:

- `positionToTime` (getBoundingClientRect)
- `containerWidth` ResizeObserver
- `usePanGesture` / `usePinchGesture` (passed through)

### Procedure

1. Create the hook file.
2. Move the listed code blocks. Keep `containerRef` creation in Timeline.
3. Receive `containerRef` as a parameter.
4. Update Timeline.tsx to call the hook and destructure results.
5. Run verification protocol.

### Critical implementation notes

- **`useTransportAnimation` callback closes over `viewport` and `maxPlayheadPosition`.** Both stay co-located inside this hook — no cross-boundary issue. The `useLayoutEffect` inside `useTransportAnimation` fires at the same commit-phase point regardless of whether it's in a custom hook or the component directly.
- **`usePlayheadDrag` and `useRegionDrag` are interleaved between viewport code blocks** (lines 375, 405). They stay in Timeline — don't accidentally move them. The extraction boundary is: everything related to viewport/coordinates/animation moves; everything related to drag interactions stays.
- **`baseTimelineStart`/`baseDuration` memo depends on `displayRegions`.** This is passed as a parameter. The memoized reference from Timeline is passed through — no instability.
- **Hook execution order changes internally** (pan/pinch now execute "inside" the viewport hook rather than at their current position), but this is safe because React tracks hooks per function boundary, and there are no data dependencies between the reordered calls.

### What to watch for

- The `useTransportAnimation` deps include `viewport` (the unstable object). This means the animation subscription unsubscribes/resubscribes every render. This is **pre-existing** behavior, not a regression. The `transportEngine.subscribe` setup/teardown is cheap (simple Set of callbacks).

### Manual verification

- Start playback in REAPER, confirm viewport follows the playhead
- Zoom in while following, confirm zoom centers on playhead
- Pan manually while following, confirm follow pauses
- Navigate via markers while stopped, confirm viewport jumps to new position

### Rollback

```
git revert <commit>
```

Or manually: restore `Timeline.tsx`, delete `useTimelineViewport.ts`, revert `hooks/index.ts`.

---

## Phase 4: `useTimelinePointerEvents()` — Gesture routing

**Risk: Moderate-High | Impact: High**

> Note: Executed LAST. Depends on Phases 1, 2, and 3 being complete.

After phases 1-3, the three pointer handlers are much smaller. Extract them as a unit.

### What moves

Lines 560-886: `handlePointerDown`, `handlePointerMove`, `handlePointerUp` (minus the item tap logic already extracted in Phase 3).

Also:

- Lines 991-1006: `selectionPreview` memo (derived from drag state used only in rendering)
- Lines 196-198: `dragStart`, `dragEnd`, `isCancelled` local state
- Line 203: `panStartPositionRef`
- Lines 66-69: `VERTICAL_CANCEL_THRESHOLD` and `TAP_THRESHOLD` constants

### Target file

`frontend/src/components/Timeline/hooks/useTimelinePointerEvents.ts`

### Interface

```ts
interface UseTimelinePointerEventsParams {
  // DOM
  containerRef: RefObject<HTMLDivElement>;   // For getBoundingClientRect in selection mode

  // Mode
  timelineMode: TimelineMode;
  selectionModeActive: boolean;

  // Gesture hooks (already extracted)
  panGesture: PanGestureReturn;
  pinchGesture: PinchGestureReturn;
  isDraggingPlayhead: boolean;

  // Region mode handlers
  handleRegionPointerDown: (e: React.PointerEvent) => void;
  handleRegionPointerMove: (e: React.PointerEvent) => void;
  handleRegionPointerUp: (e: React.PointerEvent) => void;

  // Item tap (from Phase 3)
  handleItemTap: (clientX: number, clientY: number) => boolean;

  // Viewport
  positionToTime: (clientX: number) => number;
  followPlayhead: boolean;
  pauseFollow: () => void;

  // Actions (passed in as parameters, NOT moved inside)
  setTimeSelection: (start: number, end: number) => void;
  navigateTo: (time: number) => void;
  findNearestBoundary: (time: number) => number;
}

interface UseTimelinePointerEventsReturn {
  handlePointerDown: (e: React.PointerEvent) => void;
  handlePointerMove: (e: React.PointerEvent) => void;
  handlePointerUp: (e: React.PointerEvent) => void;
  selectionPreview: { start: number; end: number } | null;
}
```

### Procedure

1. Create the hook. Move the three handlers + local drag state (`dragStart`, `dragEnd`, `isCancelled`, `panStartPositionRef`).
2. Move `selectionPreview` memo.
3. **Keep `setTimeSelection`, `navigateTo`, `findNearestBoundary` as input parameters.** They are defined in Timeline and passed in. This avoids threading `sendCommand`, `regions`, `markers`, `positionSeconds`, and `setStoredTimeSelection` into the hook.
4. Move `VERTICAL_CANCEL_THRESHOLD` and `TAP_THRESHOLD` constants into the hook file.
5. Update Timeline.tsx to destructure the four return values.
6. Run verification protocol.

### Critical implementation notes

- **This is the largest phase (~350 lines).** All three pointer handlers + their shared state form an atomic unit. You cannot move `handlePointerDown` without also moving `dragStart`/`dragEnd` which `handlePointerMove` and `handlePointerUp` read. All must move together.
- **`containerRef` is a required parameter.** `handlePointerMove` reads `containerRef.current` at lines 625, 631 for selection-mode vertical cancel detection. `handlePointerUp` reads it at line 825 for getBoundingClientRect in selection commit. This was missing from the original plan interface.
- **`dragStart`/`dragEnd` state is local to this hook.** The `selectionPreview` memo that depends on them moves too. Clean separation.
- **Hook ordering is safe.** The `useState` calls for `dragStart`/`dragEnd`/`isCancelled` currently execute at lines 196-198 (early in Timeline). After extraction they execute inside `useTimelinePointerEvents` (later in call order). This is safe because React tracks hooks per function boundary — the custom hook gets its own hook slot.
- **Consider a dry run on a branch.** This is the highest-risk phase. Branch, implement, run full E2E, then merge.

### Manual verification

- Selection mode: drag to create time selection, verify snap-to-boundary
- Selection mode: tap to navigate to nearest boundary
- Pan mode: horizontal drag to pan viewport
- Vertical cancel: drag vertically off the timeline to cancel selection
- Pinch to zoom in all modes
- Verify `onPointerCancel` (simulate by triggering system alert during drag)
- Test on mobile device with touch gestures

### Rollback

```
git revert <commit>
```

Or manually: restore `Timeline.tsx`, delete `useTimelinePointerEvents.ts`, revert `hooks/index.ts`. Note: reverting only Timeline.tsx without removing the hook file would leave dangling imports.

---

## Phase 5 (Deferred): `renderTimeToPercent` extraction

**Risk: Low if kept inline | Status: Evaluate after Phases 1-4**

### What would move

The `renderTimeToPercent` callback (lines 463-496).

### Why it's deferred

`renderTimeToPercent` depends on `isRegionDragCancelled` from `useRegionDrag`, which depends on `containerRef`/`positionToTime` from the viewport hook. This creates a **circular dependency** that prevents co-locating it with the viewport hook:

```
useTimelineViewport → returns positionToTime, containerRef
  → useRegionDrag (needs positionToTime, containerRef) → returns isRegionDragCancelled
    → renderTimeToPercent (needs isRegionDragCancelled AND viewport.visibleRange)
```

Options if extraction is desired after Phases 1-4:

- **Option A**: Leave inline in Timeline (~35 lines, not a problem).
- **Option B**: Extract as its own trivial `useRenderTimeToPercent` hook called after `useRegionDrag`, receiving all deps as parameters.

---

## Expected result

After phases 1-4, Timeline.tsx should look roughly like:

```tsx
export function Timeline({ className, height, ...props }: TimelineProps) {
  const s = useTimelineSelectors();
  const { beatsPerBar, denominator } = useTimeSignature();
  const barOffset = useBarOffset();
  const prefersReducedMotion = useReducedMotion();

  // Derived region state (display regions, drag preview) — ~40 lines, stays inline
  const displayRegions = ...;
  const baseDisplayRegions = ...;

  // DOM ref (owned by Timeline, passed to hooks)
  const containerRef = useRef<HTMLDivElement>(null);

  // Viewport, follow-playhead, coordinate conversion
  const { viewport, containerWidth, timeToPercent, ... } = useTimelineViewport({
    containerRef, ...
  });

  // Drag hooks (already extracted, just wiring)
  const playheadDrag = usePlayheadDrag({ containerRef, ... });
  const regionDrag = useRegionDrag({ containerRef, ... });
  const markerDrag = useMarkerDrag({ containerRef, ... });
  const edgeScroll = useEdgeScroll({ containerRef, ... });

  // Item tap handler
  const handleItemTap = useItemTapHandler({ containerRef, viewport, ... });

  // Action callbacks (defined here, passed to pointer events hook)
  const setTimeSelection = useCallback(...);
  const navigateTo = useCallback(...);
  const findNearestBoundary = useCallback(...);

  // Pointer event routing
  const { handlePointerDown, handlePointerMove, handlePointerUp, selectionPreview } =
    useTimelinePointerEvents({ containerRef, handleItemTap, ... });

  // Rendering-only helpers
  const renderTimeToPercent = ...;
  const visibleRegions = ...;
  const visibleMarkers = ...;
  const markerClusters = ...;

  // ~35 lines of edge scroll wrappers + marker callbacks

  return (
    <div>
      <TimelineRuler ... />
      <div> <TimelineRegionLabels ... /> <PlayheadPreviewPill ... /> </div>
      <div ref={containerRef} onPointerDown={...} onPointerMove={...} onPointerUp={...}>
        <TimelineGridLines ... />
        <TimelineRegionBlocks ... />
        <MultiTrackLanes ... />
        {/* time selection, markers, selection preview, indicators, playhead */}
      </div>
      <div> {/* bottom bar */} </div>
      <TimelineFooter ... />
    </div>
  );
}
```

Estimated final size: **~350-400 lines** (down from 1298). Each extracted hook is independently testable and understandable.
