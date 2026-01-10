# PR4 Analysis: Viewport-Aware Timeline

## Status: Research Complete - Ready to Implement

**Decisions Made:**
- ✅ Full-stack implementation (backend + frontend)
- ✅ **Pinch-to-zoom** - Continuous zoom per research recommendation (feels natural on touch)
- ✅ **Double-tap** to snap playhead to nearest marker/region (was single tap)
- ✅ **Selection mode toggle** - Distinguishes pan vs selection gestures clearly
- ✅ Defer MixerView to later PR
- ✅ Memoized filtering first (TanStack Virtual later if needed)
- ✅ Remove "add marker" button - users can add via custom toolbar action

---

## Research Results Summary

### Skeleton: YES - Positions Upfront, Details Deferred

**Verdict**: Send all marker/region positions in initial sync (~50 bytes each), defer names/colors to viewport subscription. Virtualization libraries require `itemCount` upfront for scroll dimensions - this is non-negotiable.

**Skeleton structure** (confirmed):
```typescript
interface MarkerSkeleton { id: string; position: number }        // ~20 bytes
interface RegionSkeleton { id: string; start: number; end: number } // ~30 bytes
// Names, colors loaded only for visible items via subscription
```

**Snap points**: Use visible range + 100% buffer (not all positions globally). Pre-compute candidates on viewport change, synchronous lookup during drag.

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
4. **Backend time-range subscriptions** for items/markers/regions
5. **Frontend viewport state management** with zoom/pan
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

**Already implemented (per API.md):**
- `track/subscribe` - Range and GUID modes
- `trackSkeleton` event - 1Hz, name + GUID for all tracks

**NOT yet implemented:**
- `item/subscribe { timeRange }` - Per VIEWPORT_DRIVEN_ARCHITECTURE.md "Future"
- `marker/subscribe { timeRange }`
- `region/subscribe { timeRange }`
- `markerSkeleton` / `regionSkeleton` / `itemSkeleton` events

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

### Phase 2: Backend Time-Range Subscriptions

#### 2.1 New WebSocket Commands

**File**: `frontend/src/core/WebSocketCommands.ts`

```typescript
export const item = {
  subscribe: (timeRange: TimeRange): WSCommand => ({
    command: 'item/subscribe',
    params: { timeRange },
  }),
  unsubscribe: (): WSCommand => ({
    command: 'item/unsubscribe',
  }),
};

export const marker = {
  subscribe: (timeRange: TimeRange): WSCommand => ({
    command: 'marker/subscribe',
    params: { timeRange },
  }),
  unsubscribe: (): WSCommand => ({
    command: 'marker/unsubscribe',
  }),
};

export const region = {
  subscribe: (timeRange: TimeRange): WSCommand => ({
    command: 'region/subscribe',
    params: { timeRange },
  }),
  unsubscribe: (): WSCommand => ({
    command: 'region/unsubscribe',
  }),
};
```

#### 2.2 Backend Command Handlers (Zig)

**Files to create/modify**:
- `extension/src/commands/items.zig` - Add `item/subscribe`, `item/unsubscribe`
- `extension/src/commands/markers.zig` - Add `marker/subscribe`, `marker/unsubscribe`
- `extension/src/commands/regions.zig` - Add `region/subscribe`, `region/unsubscribe`
- `extension/src/item_subscriptions.zig` - Per-client time-range state (new file)
- `extension/src/marker_subscriptions.zig` - Per-client time-range state (new file)
- `extension/src/commands/registry.zig` - Register new handlers

**Subscription state structure** (per-client):
```zig
const TimeRange = struct {
    start: f64,
    end: f64,
};

const ClientSubscription = struct {
    time_range: ?TimeRange,
    buffer: f64 = 5.0,  // 5 second buffer for edge items
};
```

**Filtering logic** (items.zig poll loop):
```zig
fn isInRange(item_start: f64, item_end: f64, range: TimeRange, buffer: f64) bool {
    return item_end > (range.start - buffer) and item_start < (range.end + buffer);
}
```

#### 2.3 useTimelineSubscription Hook

**File**: `frontend/src/hooks/useTimelineSubscription.ts`

```typescript
function useTimelineSubscription(options: {
  visibleRange: TimeRange;
  enabled?: boolean;
  buffer?: number;  // seconds, default: 30
  debounceMs?: number;  // default: 200
  sendCommand: (cmd: WSCommand) => void;
  subscribeItems?: boolean;
  subscribeMarkers?: boolean;
  subscribeRegions?: boolean;
}): void;
```

**Pattern**: Follow `useVirtualizedSubscription.ts`:
- Debounce range changes (200ms)
- Immediate re-subscribe on reconnection
- Track previous subscription to avoid redundant commands

### Phase 3: Timeline Component Integration

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
- `useTimelineSubscription.test.ts` - Debounce, reconnection

#### E2E Tests

- `timeline-viewport.spec.ts` - Drag-to-pan, pinch-to-zoom, double-tap snap, selection toggle, subscription updates

#### Gesture Test Utilities

Need to add pinch and double-tap helpers to `test/gestures.ts`.

---

## Risk Analysis

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Region drag across viewport edge** | Medium | Lock viewport during active gesture; extend viewport to include drag target |
| **Snap calculations with partial data** | Medium | Keep full region/marker positions client-side (skeleton data); only send full data for visible items |
| **Mode confusion (pan vs selection)** | Medium | Clear visual indicator on selection toggle button; consider toast/haptic feedback on mode change |
| **Performance during rapid pan** | Low | Debounce subscription updates (200ms); local rendering immediate, subscription lazy |
| **Backend subscription overhead** | Low | Filter at poll time, not per-client; shared subscription state if multiple clients have overlapping ranges |
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

| File | Purpose |
|------|---------|
| `frontend/src/hooks/useViewport.ts` | Viewport state management (pan, zoom, time↔percent) |
| `frontend/src/hooks/useViewport.test.ts` | Unit tests |
| `frontend/src/hooks/useVisibleItems.ts` | Time-range filtering |
| `frontend/src/hooks/useVisibleItems.test.ts` | Unit tests |
| `frontend/src/hooks/useTimelineSubscription.ts` | Viewport → backend sync |
| `frontend/src/hooks/useTimelineSubscription.test.ts` | Unit tests |
| `frontend/src/components/Timeline/ZoomControls.tsx` | Zoom in/out buttons + level indicator |
| `frontend/e2e/timeline-viewport.spec.ts` | E2E tests |

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
| `frontend/src/core/WebSocketCommands.ts` | Add subscribe commands for items/markers/regions |
| `frontend/src/hooks/index.ts` | Export new hooks |

### New Backend Files (Zig)

| File | Purpose |
|------|---------|
| `extension/src/item_subscriptions.zig` | Per-client time-range subscription state |
| `extension/src/marker_subscriptions.zig` | Per-client time-range subscription state |
| `extension/src/region_subscriptions.zig` | Per-client time-range subscription state |

### Modified Backend Files (Zig)

| File | Changes |
|------|---------|
| `extension/src/commands/items.zig` | Add `item/subscribe`, `item/unsubscribe` handlers |
| `extension/src/commands/markers.zig` | Add `marker/subscribe`, `marker/unsubscribe` handlers |
| `extension/src/commands/regions.zig` | Add `region/subscribe`, `region/unsubscribe` handlers |
| `extension/src/commands/registry.zig` | Register new command handlers |
| `extension/src/items.zig` | Filter items by subscribed time range in poll loop |
| `extension/src/markers.zig` | Filter markers by subscribed time range in poll loop |
| `extension/API.md` | Document new subscription commands |

---

## Implementation Order

```
Phase 1: Frontend Hooks (No backend changes yet)
├── useViewport.ts + tests (pan, zoom steps, time↔percent)
└── useVisibleItems.ts + tests

Phase 2: Backend Subscriptions
├── item_subscriptions.zig
├── marker_subscriptions.zig
├── region_subscriptions.zig
├── Command handlers + registry
└── API.md documentation

Phase 3: Frontend Integration
├── useTimelineSubscription.ts + tests
├── WebSocketCommands.ts additions
└── Timeline.tsx viewport state integration

Phase 4: UI Changes
├── Timeline.tsx drag-to-pan in navigation mode
├── ZoomControls.tsx (+ / - buttons, level indicator)
├── SelectionButton.tsx (toggle behavior, long-press)
├── Actions/index.ts (remove add marker, add zoom controls)
├── TimelineRegions.tsx filtering
├── TimelineMarkers.tsx filtering
└── ItemDensityBlobs.tsx filtering

Phase 5: Testing & Polish
├── timeline-viewport.spec.ts (E2E)
└── Accessibility (prefers-reduced-motion)
```

---

## User Decisions (Captured)

| Decision | Choice |
|----------|--------|
| **Zoom interaction** | **Pinch-to-zoom** (continuous) + zoom buttons as secondary |
| **Timeline tap** | **Double-tap** to snap playhead to nearest marker/region (was single tap) |
| **Navigation mode drag** | Single-finger drag = pan viewport (not time selection) |
| **Selection toggle** | Existing selection button becomes toggle; long-press for manual entry |
| **Add marker button** | **REMOVED** - Users can add via custom toolbar action (40157) |
| Snap behavior | Use ALL snap points (keep full positions client-side via skeleton) |
| Default zoom | Mobile-first ~30 seconds |
| PR strategy | **Backend first** → test via websocat → then frontend. Can break/delete old APIs during dev. |

---

## Skeleton Events: Minimal Data for Large Projects

Like `trackSkeleton` for tracks, we need lightweight skeleton events that provide minimal positioning data regardless of project size. This enables:
- Snap point calculations (need ALL positions)
- Viewport-aware filtering (know what to subscribe to)
- Overview visualization (e.g., minimap)

### Skeleton Event Payloads

| Event | Minimal Fields | Rationale |
|-------|---------------|-----------|
| `regionSkeleton` | `id`, `start`, `end`, `color` | Position for snapping + color for overview bar |
| `markerSkeleton` | `id`, `position`, `color` | Position for snapping + color for indicator |
| `itemSkeleton` | `trackGuid`, `start`, `end` | Position only - used for density blobs |

**NOT included in skeleton** (sent only for subscribed items):
- Region/marker names (text is expensive, only needed when visible)
- Item details (waveform data, takes, etc.)

**Broadcast frequency**: 1Hz (same as trackSkeleton)

---

## Subscription Buffer Strategy

### Buffer Size: 100% of Visible Duration

Per research: apps use **visible range + 100% buffer on each side** for snap points.

| Visible Duration | Buffer Each Side | Total Subscribed |
|-----------------|------------------|------------------|
| 5s | 5s | 15s |
| 30s | 30s | 90s |
| 60s | 60s | 180s |

**Formula**: `buffer = visibleDuration * 1.0` (100% each side)

Pre-compute snap candidates on viewport change, then synchronous lookup during drag.

### Edge Cases: Start/End of Project

| Scenario | Behavior |
|----------|----------|
| Viewport includes t=0 | Clamp subscription start to 0, no negative times |
| Viewport includes project end | Clamp subscription end to projectDuration |
| Full project visible | Subscribe to entire project (no filtering benefit, but still works) |
| Playhead outside viewport | Viewport stays where user put it; playhead indicator shows direction arrow at edge |

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

### Regions at Low Zoom

**Progressive degradation**:
1. **Full name fits** → Show full name
2. **Name too long** → CSS `text-overflow: ellipsis` truncation
3. **Can't fit ANY text** → Color bar only (no label)
4. **Region too narrow** → Minimum 2px width, just a colored line

**CSS implementation**:
```css
.region-label {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  min-width: 0;
}
```

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

### PR4a: Backend Time-Range Subscriptions

**Scope**: All backend work, test via websocat, update API.md

**Deliverables**:
1. `item_subscriptions.zig` - Per-client time-range state
2. `marker_subscriptions.zig` - Per-client time-range state
3. `region_subscriptions.zig` - Per-client time-range state
4. Command handlers: `item/subscribe`, `marker/subscribe`, `region/subscribe` (+ unsubscribe)
5. Poll loop filtering by subscribed time range
6. Updated `API.md` with new commands
7. Websocat test scripts for verification

**Can break/change**:
- Existing marker/region/item event formats if needed
- Maintain changelog for frontend awareness

### PR4b: Frontend Viewport Integration

**Scope**: All frontend work, depends on PR4a APIs

**Deliverables**:
1. `useViewport.ts` + tests (pan, zoom steps, time↔percent conversion)
2. `useVisibleItems.ts` + tests
3. `useTimelineSubscription.ts` + tests
4. `WebSocketCommands.ts` updates
5. `Timeline.tsx` integration (viewport state, drag-to-pan in nav mode)
6. `ZoomControls.tsx` (zoom buttons + level indicator)
7. `SelectionButton.tsx` modifications (toggle + long-press)
8. `Actions/index.ts` changes (remove add marker, add zoom controls)
9. E2E tests

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

- `research/VIEWPORT_ANALYSIS.md` - LOD, density visualization, performance thresholds (completed research)
- `research/TIMELINE_SCROLL_BEHAVIOUR.md` - End-of-timeline UX decisions
- `VIEWPORT_DRIVEN_ARCHITECTURE.md` - Subscription protocol design
- `FRONTEND_DEVELOPMENT.md` - Frontend patterns and best practices
- `DEVELOPMENT.md` - Full-stack conventions
- `frontend/src/hooks/useVirtualizedSubscription.ts` - Subscription pattern to follow
- `frontend/src/components/Timeline/hooks/useRegionDrag.ts` - Gesture pattern to follow
