# PR4 Analysis: Viewport-Aware Timeline

## Status: In Progress

**Implemented:**
- ✅ Full-stack implementation (backend broadcast + frontend viewport)
- ✅ **Zoom buttons** (+/-) with discrete zoom steps
- ✅ **Selection mode toggle** - Distinguishes pan vs selection gestures
- ✅ **Marker clustering** - 40px merge threshold with count badges
- ✅ **Follow playhead** - Auto-scroll during playback with soft-end bounds
- ✅ **Edge scroll** - Auto-pan when dragging to container edge
- ✅ **Accessibility** - prefers-reduced-motion support
- ✅ Memoized filtering (useVisibleItems hook)
- ✅ Remove "add marker" button - users can add via custom toolbar action
- ✅ **Region label LOD** - 40px threshold with overlap-aware text clipping

**Remaining:**
- 🔲 **Double-tap to snap** - Pre-req for pinch gesture (currently single-tap snaps)
- 🔲 **Pinch-to-zoom** - Primary zoom gesture per research
- 🔲 **Item density LOD** - 0-30% bars, 30-60% clusters, 60-100% individual
- 🔲 **Interval tree** - For >500 items snap queries

**Separate PRs:**
- ⏸️ MixerView
- ⏸️ TanStack Virtual (if needed)

---

## Research Results Summary

### Skeleton: NO - Full Data Broadcast (Simplified)

**Verdict**: Send full marker/region data to all clients (broadcast). Skeleton events were removed as premature optimization - bandwidth is negligible over LAN and most users want full data immediately.

**Simplified architecture**:
- **Markers/regions/items**: All broadcast to all clients at 5Hz, included in snapshot on connect
- Frontend filters to visible viewport for rendering (no subscription required)

**Snap points**: Full marker/region/item data always available client-side. Pre-compute candidates on viewport change, synchronous lookup during drag.

### Density Visualization: 40px Merge Threshold

**Pattern**: Merge items within **40 pixels** of each other at current zoom, display aggregate count on merged blobs.

| Zoom level | Behavior |
|------------|----------|
| 0-30% | Solid density bars with item count label |
| 30-60% | Merged clusters showing "N items" |
| 60-100% | Individual item rectangles |

**No heatmaps** - professional NLEs use minimum 1-2px rendering, small gaps visually disappear.

### Realistic Scale for Home Producers

| Metric | Typical | "Large" |
|--------|---------|---------|
| Tracks | 20-50 | 100+ |
| Items | 50-200 | 500+ |
| Markers | 5-20 | 100+ |
| Regions | 5-15 | 50+ |

**Typical song**: 7-10 arrangement sections → ~10 markers, ~8 regions.

### Zoom: Pinch-to-Zoom with 2x Steps

- **Pinch-to-zoom** primary gesture (continuous, feels natural on touch)
- **Zoom buttons** as secondary control (+ / - with 2x ratio steps)
- **8-12 zoom levels** from "full project" to "beats visible"
- **Don't go sample-level** on iPad - unnecessary for remote control
- **Zoom-to-fit** essential quick action

### Performance Thresholds

| Metric | Safe | Performance cliff |
|--------|------|-------------------|
| DOM elements in viewport | **200** | 500+ causes jank |
| Linear search items | **100** | Use binary search above |
| Interval tree threshold | **500** | Use `interval-tree-1d` above |
| Snap query target | **<0.5ms** | Pre-compute on viewport change |

### Degradation Strategy: Visual Density, No Warnings

**Never show "project too large" errors**. Degrade gracefully:
- Merged blobs show count ("14 items")
- Opacity correlates with item count
- More zoom = more detail (300-600ms spring animation)
- At memory pressure: drop mipmap quality, not features

---

## Executive Summary

PR4 implements a **viewport-aware timeline** with:
1. **Drag-to-pan in navigation mode** - Single touch/drag moves viewport horizontally
2. **Zoom in/out buttons** - Discrete zoom controls for changing visible time range
3. **Selection toggle** - Tap to toggle selection mode; long-press for manual selection entry
4. **Backend broadcasts** all data (markers/regions/items) to all clients
5. **Frontend viewport state management** with zoom/pan and local filtering
6. **Smooth scroll behavior** per research/TIMELINE_SCROLL_BEHAVIOUR.md

**MixerView is deferred** to a future PR.
**Markers: "Add marker" button removed** - Users can add markers via custom toolbar button (action 40157). MarkerInfoBar may be repurposed or replaced with context-aware UI later.

---

## Current State Analysis

### Timeline Implementation (Timeline.tsx - 710 lines)

**Current architecture:**
- **Stretch-to-fit rendering** - All content scaled to fit container width
- **No native zoom** - Timeline bounds calculated dynamically from content
- **All items rendered** - No virtualization for regions/markers/items
- **30Hz full updates** - All regions/markers/items received regardless of viewport

**Key files:**
- `Timeline.tsx` - Main orchestrator, gesture handling
- `TimelineRegions.tsx` - Region rendering (labels + blocks)
- `TimelineMarkers.tsx` - Marker rendering (lines + pills)
- `TimelinePlayhead.tsx` - 60fps interpolation via ref-based DOM mutation
- `ItemDensityBlobs.tsx` - Item aggregation visualization
- `useRegionDrag.ts` - Move/resize gesture logic (437 lines)

**Performance concerns for large projects:**
- All regions rendered as DOM elements (`.map()` over full array)
- All markers rendered (100+ markers = performance issues)
- Items density processes ALL items even if off-screen
- Snap calculations iterate over ALL regions/markers

### Virtualization Patterns (Working POC)

**VirtualizedTrackList** - TanStack Virtual integration:
```typescript
const virtualizer = useVirtualizer({
  count: trackCount,
  getScrollElement: () => scrollElement,
  estimateSize: () => TRACK_WIDTH,
  horizontal: true,
  overscan: 5,
});
```

**useVirtualizedSubscription** - Viewport → subscription bridge:
- Converts visible virtual items to subscription range
- 200ms debounce on scroll
- Immediate re-subscribe on reconnection
- Range mode (scrolling) vs GUID mode (filtered views)

### Backend API Status

**Implemented (per API.md):**
- `track/subscribe` - Range and GUID modes
- `trackSkeleton` event - 1Hz, name + GUID for all tracks
- `markers` event - 5Hz, broadcast to all clients
- `regions` event - 5Hz, broadcast to all clients
- `items` event - 5Hz, broadcast to all clients (no subscription required)

---

## Critical UX Research: Timeline Scroll Behavior

**Source**: `research/TIMELINE_SCROLL_BEHAVIOUR.md`

### Key Design Decisions (Already Researched)

1. **Fixed playhead position**: 1/3 from left edge during playback
2. **End-of-timeline behavior**: Hybrid deceleration with playhead drift (not hard stop)
3. **Transition zone**: Triggers when ~15% of visible width remains
4. **State machine**: NORMAL_SCROLL → TRANSITION → END_HOLD → LOOP_TRANSITION
5. **Accessibility**: Must respect `prefers-reduced-motion`

### Scroll State Machine

```
States:
  NORMAL_SCROLL    - Playhead at 1/3, timeline scrolls
  TRANSITION       - Decelerating, playhead drifts right
  END_HOLD         - At project end, static view
  LOOP_TRANSITION  - Preparing for loop restart
```

### Implementation Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `PLAYHEAD_POSITION` | 0.33 | Normal playhead screen position |
| `TRANSITION_TRIGGER` | 0.50 | Start transition when remaining < 50% of visible width |
| `END_VELOCITY_FACTOR` | 0.20 | Minimum scroll velocity in transition |
| `SMOOTHING_SCROLL` | 0.85 | Frame-rate-independent smoothing |
| `SMOOTHING_PLAYHEAD` | 0.90 | Slower smoothing for intentional feel |

---

## Implementation Plan

### Phase 1: Core Viewport Hooks (Frontend Foundation)

#### 1.1 useViewport Hook

**File**: `frontend/src/hooks/useViewport.ts`

```typescript
interface TimeRange {
  start: number;  // seconds
  end: number;    // seconds
}

interface ViewportState {
  visibleRange: TimeRange;
  zoomLevel: number;  // 1.0 = default, >1 = zoomed in
  projectDuration: number;
}

interface UseViewportResult {
  state: ViewportState;
  visibleRange: TimeRange;
  zoomLevel: number;  // Index into ZOOM_STEPS
  visibleDuration: number;  // seconds currently visible
  pan: (deltaSeconds: number) => void;
  zoomIn: () => void;   // Step to next smaller duration
  zoomOut: () => void;  // Step to next larger duration
  setVisibleRange: (range: TimeRange) => void;
  reset: () => void;
  fitToContent: (contentRange: TimeRange) => void;
  timeToPercent: (time: number) => number;
  percentToTime: (percent: number) => number;
  isInView: (start: number, end: number, buffer?: number) => boolean;
}

// Discrete zoom steps (seconds visible)
const ZOOM_STEPS = [5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600];
```

**Implementation notes**:
- Use `useReducer` for predictable state transitions
- Clamp range to `[0, projectDuration]`
- Zoom in/out snaps to ZOOM_STEPS for predictable behavior
- When zooming, keep center of current view as anchor point
- `timeToPercent`/`percentToTime` are hot functions - memoize with `useCallback`

#### 1.2 Navigation Mode Behavior

**Context**: User switches between Navigation, Items, and Regions modes. In Navigation mode, the timeline behavior changes:

**Current behavior** (to be changed):
- Drag on timeline = time selection
- Single tap = snap playhead to nearest marker/region

**New behavior** (PR4):
- **Single-finger drag** = pan viewport horizontally
- **Pinch-to-zoom** = continuous zoom (primary zoom method)
- **Double-tap** = snap playhead to nearest marker/region (was single tap)
- **Time selection** = disabled by default; toggle into selection mode

**Selection Toggle Button**:
- **Location**: Replaces/repurposes existing selection button in action bar
- **Tap**: Toggle between pan-mode and selection-mode within Navigation mode
- **Long-press**: Open manual selection entry dialog (start/end time input)
- **Visual state**: Clear active/inactive indicator (color change when selection mode active)

**Gesture summary** (Navigation mode):
| Gesture | Pan mode (default) | Selection mode |
|---------|-------------------|----------------|
| Single-finger drag | Pan viewport | Create time selection |
| Pinch | Zoom in/out | Zoom in/out |
| Double-tap | Snap to marker/region | Snap to marker/region |

#### 1.3 useVisibleItems Hook

**File**: `frontend/src/hooks/useVisibleItems.ts`

```typescript
function useVisibleItems<T>(options: {
  items: T[];
  getStart: (item: T) => number;
  getEnd?: (item: T) => number;
  visibleRange: TimeRange;
  buffer?: number;  // seconds, default: 10
}): {
  visibleItems: T[];
  count: number;
  total: number;
}
```

**Implementation notes**:
- Include items that span viewport edges (start < visibleEnd && end > visibleStart)
- Buffer prevents items from "popping" during small pans
- Memoize with `useMemo` keyed on range + buffer

### Phase 2: Backend Broadcast (All Data) ✅ IMPLEMENTED

> **Further Simplified**: All data (markers/regions/items) broadcast to all clients. No subscription commands needed.

#### 2.1 No WebSocket Commands Needed

Items are broadcast automatically like markers and regions. Frontend filters to visible viewport locally.

```typescript
// Frontend receives all items via 'items' event
const allItems = useReaperData().items;

// Filter to viewport for rendering
const visibleItems = useMemo(() =>
  allItems.filter(item =>
    item.position < viewportEnd &&
    (item.position + item.length) > viewportStart
  ),
  [allItems, viewportStart, viewportEnd]
);
```

#### 2.2 Backend Implementation

**Poll loop broadcasts all data at 5Hz (MEDIUM tier)**:
- `markers` event - when markers change
- `regions` event - when regions change
- `items` event - when items change

**Hash-based change detection** ensures events only sent when data actually changes.

**Files removed** (subscription system no longer needed):
- ~~`extension/src/timeline_subscriptions.zig`~~
- ~~`extension/src/commands/timeline_subs.zig`~~

### Phase 3: Timeline Component Integration ✅ COMPLETE

> **Status:** Implemented. See `docs/PHASE3_FRONTEND_INTEGRATION.md` for details.

#### 3.1 Timeline.tsx Changes

1. **Add viewport state**:
   ```typescript
   const { visibleRange, pan, zoomIn, zoomOut, timeToPercent } = useViewport({
     projectDuration,
     initialRange: { start: 0, end: 30 },  // 30 seconds default
   });
   ```

2. **Modify drag behavior in navigation mode**:
   ```typescript
   // In navigation mode with pan enabled (not selection mode):
   const handleDrag = (deltaX: number) => {
     if (mode === 'navigate' && !selectionModeActive) {
       // Convert pixel delta to time delta
       const timeDelta = (deltaX / containerWidth) * (visibleRange.end - visibleRange.start);
       pan(-timeDelta);  // Negative because dragging right = moving backward in time
     }
   };
   ```

3. **Filter items**:
   ```typescript
   const visibleRegions = useVisibleItems({
     items: regions,
     getStart: (r) => r.start,
     getEnd: (r) => r.end,
     visibleRange,
   });
   ```

4. **Update coordinate conversion**:
   - Replace `timeToPercent` based on full timeline with viewport-relative
   - Update all region/marker positioning

5. **Add scroll behavior state machine** per TIMELINE_SCROLL_BEHAVIOUR.md

#### 3.2 CSS Requirements

```css
.timeline-container {
  touch-action: none;  /* Prevent browser zoom */
  -webkit-user-select: none;
  user-select: none;
}
```

### Phase 4: Zoom Controls & Selection Toggle UI

#### 4.1 ZoomControls Component

**File**: `frontend/src/components/Timeline/ZoomControls.tsx`

**Primary controls** (visible in navigation mode):
- **Zoom out button** (−): Increases visible time range (show more timeline)
- **Zoom in button** (+): Decreases visible time range (show less timeline, more detail)
- **Zoom level indicator**: Shows current visible duration (e.g., "30s", "2m", "10m")
- **Fit-to-content button**: Resets viewport to show full project

**Zoom step behavior**:
```typescript
const ZOOM_STEPS = [5, 10, 15, 30, 60, 120, 300, 600, 1800]; // seconds
// Zoom in/out snaps to nearest step for predictable behavior
```

**Location**: Replaces "add marker" button area in action bar

#### 4.2 Selection Toggle Button

**File**: Modify existing selection button in action bar

**Behavior**:
- **Tap**: Toggle `selectionModeActive` state
- **Long-press**: Open time selection dialog (numeric input for start/end)
- **Visual indicator**: Color/opacity change when active vs inactive

**State flow**:
```
Navigation Mode (default)
├── Pan mode (selectionModeActive = false) ← DEFAULT
│   ├── Single-finger drag = pan viewport
│   ├── Pinch = zoom in/out
│   └── Double-tap = snap to marker/region
└── Selection mode (selectionModeActive = true)
    ├── Single-finger drag = create time selection
    ├── Pinch = zoom in/out
    └── Double-tap = snap to marker/region
```

### Phase 5: Testing

#### Unit Tests

- `useViewport.test.ts` - State transitions, bounds clamping, pan behavior, zoom steps
- `useVisibleItems.test.ts` - Filtering edge cases

#### E2E Tests

- `timeline-viewport.spec.ts` - Drag-to-pan, pinch-to-zoom, double-tap snap, selection toggle

#### Gesture Test Utilities

Need to add pinch and double-tap helpers to `test/gestures.ts`.

---

## Risk Analysis

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Region drag across viewport edge** | Medium | Lock viewport during active gesture; extend viewport to include drag target |
| **Snap calculations with partial data** | Low | All data broadcast — full marker/region/item data always available client-side |
| **Mode confusion (pan vs selection)** | Medium | Clear visual indicator on selection toggle button; consider toast/haptic feedback on mode change |
| **Performance during rapid pan** | Low | Local filtering only — no backend round-trip needed |
| **Pinch gesture on Safari PWA** | Medium | Test thoroughly on iOS Safari; use touch-action: none; track touchIdentifier carefully |
| **Pinch vs pan gesture conflict** | Low | Selection mode toggle clearly separates behaviors; pinch always zooms in both modes |

### Accessibility Requirement

**Must support `prefers-reduced-motion`**:
- Disable smooth transitions
- Use instant snap instead of deceleration
- Binary behavior (scrolling → stopped) at project end

```typescript
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
```

---

## Files to Create/Modify

### New Frontend Files

| File | Status | Purpose |
|------|--------|---------|
| `frontend/src/hooks/useViewport.ts` | ✅ | Viewport state management (pan, zoom, time↔percent) |
| `frontend/src/hooks/useViewport.test.ts` | ✅ | Unit tests (31 tests) |
| `frontend/src/hooks/useVisibleItems.ts` | ✅ | Time-range filtering (local, no backend calls) |
| `frontend/src/hooks/useVisibleItems.test.ts` | ✅ | Unit tests (15 tests) |
| `frontend/src/components/Timeline/ZoomControls.tsx` | ✅ | Zoom in/out buttons + level indicator |
| `frontend/src/components/Timeline/hooks/usePanGesture.ts` | ✅ | Pan gesture for viewport navigation |
| `frontend/src/components/Timeline/hooks/usePanGesture.test.ts` | ✅ | Unit tests (17 tests) |
| `frontend/e2e/timeline-viewport.spec.ts` | 🔲 Optional | E2E tests for viewport interactions |

### Modified Frontend Files

| File | Changes |
|------|---------|
| `frontend/src/components/Timeline/Timeline.tsx` | Add viewport state, drag-to-pan in nav mode, item filtering |
| `frontend/src/components/Timeline/TimelineRegions.tsx` | Use `useVisibleItems` for filtering |
| `frontend/src/components/Timeline/TimelineMarkers.tsx` | Use `useVisibleItems` for filtering |
| `frontend/src/components/Timeline/ItemDensityBlobs.tsx` | Use `useVisibleItems` for filtering |
| `frontend/src/components/Timeline/hooks/useRegionDrag.ts` | Viewport-aware coordinate conversion |
| `frontend/src/components/Actions/index.ts` | Remove "add marker" button, add zoom controls |
| `frontend/src/components/Actions/SelectionButton.tsx` | Add toggle behavior + long-press for manual entry |
| `frontend/src/hooks/index.ts` | Export new hooks |

### Backend Files (Zig) ✅ IMPLEMENTED

| File | Purpose |
|------|---------|
| `extension/src/items.zig` | `computeHash()` for change detection |
| `extension/src/markers.zig` | Hash functions for change detection |
| `extension/src/main.zig` | Poll loop broadcasts items like markers/regions |
| `extension/API.md` | Document items event (broadcast, no subscription) |

> **Note:** `timeline_subscriptions.zig` and `commands/timeline_subs.zig` were removed — items now broadcast to all clients.

---

## Implementation Order

```
Phase 1: Frontend Hooks ✅ COMPLETE
├── useViewport.ts + tests (pan, zoom steps, time↔percent)
├── useVisibleItems.ts + tests (local filtering)
└── ZoomControls.tsx (zoom buttons + level indicator)

Phase 2: Backend Broadcast ✅ COMPLETE
├── Items broadcast to all clients (like markers/regions)
├── Hash-based change detection
└── API.md documentation

Phase 3: Frontend Integration ✅ COMPLETE
│   See: docs/PHASE3_FRONTEND_INTEGRATION.md for details
├── ✅ usePanGesture.ts + tests (17 tests)
├── ✅ Timeline.tsx viewport state + pan gesture
├── ✅ Viewport-relative rendering (renderTimeToPercent)
├── ✅ useVisibleItems filtering wired to child components
└── ✅ Selection mode toggle state

Phase 4: UI Controls ✅ COMPLETE
├── ✅ ZoomControls overlay (bottom-right of timeline)
├── ✅ SelectionToggle button (Crosshair icon)
└── ✅ Controls only visible in navigate mode

Phase 5: Testing & Polish ✅ COMPLETE
├── ✅ timeline-viewport.spec.ts (E2E - pan, zoom, selection, reduced motion)
├── ✅ Accessibility (useReducedMotion hook, CSS prefers-reduced-motion)
├── ✅ Marker clustering (useMarkerClusters hook, 40px merge threshold)
├── ✅ Follow playhead (animation engine subscription, soft-end bounds)
├── ✅ Edge scroll (useEdgeScroll hook for drag-to-edge panning)
└── ✅ Unit tests (useReducedMotion, useMarkerClusters, useEdgeScroll)
```

---

## User Decisions (Captured)

| Decision | Choice | Status |
|----------|--------|--------|
| **Zoom interaction** | **Pinch-to-zoom** (continuous) + zoom buttons as secondary | 🔲 Pinch TODO, ✅ Buttons done |
| **Timeline tap** | **Double-tap** to snap playhead to nearest marker/region | 🔲 TODO (currently single-tap) |
| **Navigation mode drag** | Single-finger drag = pan viewport (not time selection) | ✅ Done |
| **Selection toggle** | Existing selection button becomes toggle; long-press for manual entry | ✅ Done |
| **Add marker button** | **REMOVED** - Users can add via custom toolbar action (40157) | ✅ Done |
| Snap behavior | Full marker/region data always available (broadcast, no skeleton needed) | ✅ Done |
| Default zoom | Mobile-first ~30 seconds | ✅ Done |
| **Item density LOD** | 0-30% bars, 30-60% clusters, 60-100% individual | 🔲 TODO |
| **Interval tree** | For >500 items snap queries | 🔲 TODO |

---

## ~~Skeleton Events~~ REMOVED

> **Simplified (2026-01-10)**: Skeleton events were removed as premature optimization. Full marker/region data is broadcast to all clients. Bandwidth is negligible over LAN.

---

## ~~Subscription Buffer Strategy~~ REMOVED

> **Simplified (2026-01-10)**: Subscription system removed. All items broadcast to all clients. Frontend filters locally to visible viewport.

### Frontend Filtering (Simple)

```javascript
// All items arrive automatically via 'items' event
const allItems = useReaperData().items;

// Filter to viewport for rendering (with optional buffer for smooth scrolling)
const buffer = (viewportEnd - viewportStart) * 0.5;  // 50% buffer each side
const visibleItems = useMemo(() =>
  allItems.filter(item =>
    item.position < viewportEnd + buffer &&
    (item.position + item.length) > viewportStart - buffer
  ),
  [allItems, viewportStart, viewportEnd, buffer]
);
```

### Edge Cases

| Scenario | Behavior |
|----------|----------|
| Playhead outside viewport | Viewport stays where user put it; playhead indicator shows direction arrow at edge |
| Large projects | Frontend handles filtering efficiently; optimize with binary search if >500 items |

---

## Clutter Handling: Definitive Decisions

### Markers at Low Zoom (40px Merge Threshold)

Per research: use **40 pixels** as merge threshold (Mapbox Supercluster default).

1. **Spacing ≥ 40px**: Show individual markers with labels
2. **Spacing < 40px**: Merge into clusters showing count ("5 markers")
3. **Extreme density**: Solid density bar with total count

```
High zoom:  |1    |2    |3    |4    |5     (individual)
Med zoom:   |●3        |●2                 (merged clusters)
Low zoom:   ████████████  (12 markers)     (density band)
```

### Regions at Low Zoom ✅ IMPLEMENTED

**Progressive degradation**:
1. **Full name fits** → Show full name
2. **Name too long** → CSS `text-overflow: ellipsis` truncation
3. **Can't fit ANY text** → Color bar only (no label)
4. **Region too narrow** → Minimum 2px width, just a colored line

**Implementation** (see [TimelineRegions.tsx](frontend/src/components/Timeline/TimelineRegions.tsx)):

```typescript
const REGION_LABEL_MIN_WIDTH_PX = 40;

// Find earliest overlapping region that starts within this region's bounds
// Text clips at that boundary to avoid overwriting shorter regions
const overlappingStarts = displayRegions
  .filter(r => r.id !== region.id && r.start > region.start && r.start < region.end)
  .map(r => r.start);
const earliestOverlap = overlappingStarts.length > 0 ? Math.min(...overlappingStarts) : null;

// Calculate effective width (clipped at overlap boundary)
const effectiveEnd = earliestOverlap ?? region.end;
const effectivePixelWidth = containerWidth ? (effectivePercentWidth / 100) * containerWidth : Infinity;

// LOD: hide name if effective (clipped) width is too narrow
const showName = effectivePixelWidth >= REGION_LABEL_MIN_WIDTH_PX;

// Text max-width as percentage of parent (clips at overlap boundary)
const textMaxWidthPercent = earliestOverlap !== null
  ? ((earliestOverlap - region.start) / (region.end - region.start)) * 100
  : 100;
```

**Key behaviors**:
- **40px threshold**: Region names hidden when effective width < 40px
- **Overlap-aware**: Uses clipped width (at next overlapping region), not full region width
- **CSS clip**: `max-width` percentage prevents text from overwriting shorter overlapping regions
- **Color bar always visible**: Even when name is hidden, the 5px color bar renders

### Spanning Regions: "Current Section" Indicator

When a region extends beyond the viewport, show directional context:

| Scenario | Display |
|----------|---------|
| Region starts before viewport, ends within | `← Bridge` (left arrow prefix) |
| Region starts within viewport, ends after | `Bridge →` (right arrow suffix) |
| Region spans entire viewport (both edges) | `← Bridge →` (both arrows) |
| Region fully within viewport | `Bridge` (no arrows) |

**Implementation**: Check `region.start < visibleRange.start` and `region.end > visibleRange.end`

### Overlapping Regions

Regions can overlap. At the current viewport, multiple regions may cover the same time position.

**Display strategy** (stacked pills at top):
```
┌─────────────────────────────────────────┐
│ [Verse] [Chorus] +2                     │  ← Region indicator bar
├─────────────────────────────────────────┤
│                                         │
│           Timeline content              │
│                                         │
└─────────────────────────────────────────┘
```

- Show top 2 region pills (most recently started, or by render order)
- If more than 2 overlap at current position: show `+N` overflow badge
- Tap on overflow → expand to show all (or show in a popover)

**"Current position" for overlap detection**: Use playhead position OR viewport center when stopped.

---

## Additional Edge Cases

### Playhead Position vs Viewport

| Scenario | Behavior |
|----------|----------|
| Playhead within viewport | Normal rendering |
| Playhead left of viewport | Show `◀` indicator at left edge with time offset |
| Playhead right of viewport | Show `▶` indicator at right edge with time offset |
| User pans away during playback | Auto-scroll disabled; show "catch up" button? |

### Gesture Edge Cases

| Scenario | Behavior |
|----------|----------|
| Zooming while region drag active | Lock zoom during drag gesture |
| Pan to reveal more of dragged region | Allow pan during drag (viewport follows if near edge) |
| Time selection extends beyond viewport | Selection clamped to project bounds, shown as extending off-edge |

### Very Short/Long Elements

| Element | Too Short | Too Long |
|---------|-----------|----------|
| Region (< 2px width at zoom) | Render as 2px colored line | Normal rendering |
| Marker label | Hide label, keep line | Truncate with ellipsis |
| Item (< 1px width) | Skip rendering entirely | Normal (density blob handles) |

### Loop Region Visualization

| Scenario | Behavior |
|----------|----------|
| Loop region fully visible | Show both loop start/end markers with connecting region |
| Loop extends beyond viewport | Show visible portion, with `←`/`→` indicators |
| Loop region at low zoom | Same degradation as normal regions |

### Double-Tap on Timeline

**Already handled**: Single tap = jump to nearest snap point (marker, region boundary). Playhead can be dragged for fine control. No additional double-tap behavior planned.

### Initial Viewport Position

| Scenario | Behavior |
|----------|----------|
| App loads | Center viewport on playhead position |
| Playhead at t=0 | Show timeline starting at t=0 |
| Project duration changes | Stay at current viewport (don't auto-expand) |

### Touch Target Accessibility

Minimum 44px touch target (iOS HIG) even when visual element is smaller at low zoom.

---

## ~~Open Questions~~ RESOLVED: Zoom Limits & Scale

**All questions resolved via research.** See "Research Results Summary" at top of document.

| Question | Answer |
|----------|--------|
| Skeleton necessary? | YES - positions upfront, details deferred |
| Discrete gaps visualization | 40px merge threshold, show counts |
| Realistic scale | 50-200 items, 5-20 markers typical |
| Zoom approach | Continuous with 2x steps, 8-12 levels |
| Performance thresholds | 200 DOM max, interval-tree at 500+ |
| Degradation strategy | Visual density indicators, no warnings |

---

## ~~Research Query~~ COMPLETE

Research completed. Full output archived to `research/VIEWPORT_ANALYSIS.md`.

Results integrated into "Research Results Summary" section at top of document.

---

## Revised PR Strategy

### PR4a: Backend Broadcast ✅ COMPLETE

**Scope**: All backend work, test via websocat, update API.md

**Deliverables** (further simplified):
1. Items broadcast to all clients (like markers/regions)
2. Hash-based change detection in poll loop
3. Updated `API.md` documenting items event

**Simplified from subscription model**:
- No `timeline/subscribe` or `timeline/unsubscribe` commands
- All data (markers/regions/items) broadcast to all clients
- Frontend filters locally — instant scroll/zoom, no round-trip
- Subscription files removed: `timeline_subscriptions.zig`, `commands/timeline_subs.zig`

### PR4b: Frontend Viewport Integration ✅ COMPLETE

**Scope**: All frontend work (no backend API dependencies!)

**Deliverables**:
1. ✅ `useViewport.ts` + tests (pan, zoom steps, time↔percent conversion)
2. ✅ `useVisibleItems.ts` + tests (local filtering)
3. ✅ `ZoomControls.tsx` (zoom buttons + level indicator)
4. ✅ `Timeline.tsx` integration (viewport state, drag-to-pan in nav mode)
5. ✅ `usePanGesture.ts` + tests (pan gesture hook)
6. ✅ SelectionToggle button (Crosshair icon for mode toggle)
7. 🔲 E2E tests (optional)

### PR4c: Zoom-Dependent Detail (Research Complete)

**Scope**: Implement LOD rendering per research findings

**Deliverables** (based on research):
- 40px merge threshold for marker clustering (Mapbox Supercluster pattern)
- Hierarchical density visualization (0-30% solid bars, 30-60% clusters, 60-100% individual)
- Item count display on merged blobs ("14 items")
- `interval-tree-1d` integration for snap queries (>500 items)
- 200 DOM element cap in viewport
- 300-600ms spring animations for zoom transitions

---

## References

- `docs/PHASE3_FRONTEND_INTEGRATION.md` - Phase 3 implementation plan (✅ complete)
- `research/VIEWPORT_ANALYSIS.md` - LOD, density visualization, performance thresholds (completed research)
- `research/TIMELINE_SCROLL_BEHAVIOUR.md` - End-of-timeline UX decisions
- `TIMELINE_V2_BACKEND_PLAN.md` - Backend implementation details
- `FRONTEND_DEVELOPMENT.md` - Frontend patterns and best practices
- `DEVELOPMENT.md` - Full-stack conventions
- `frontend/src/components/Timeline/hooks/useRegionDrag.ts` - Gesture pattern to follow
