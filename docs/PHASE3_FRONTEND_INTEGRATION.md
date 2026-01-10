# Phase 3: Frontend Integration - Detailed Implementation Plan

**Status:** ✅ Complete (UI controls integrated)
**Prerequisite:** Phase 1 complete (useViewport, useVisibleItems, ZoomControls)
**Scope:** Integrate viewport state into Timeline.tsx and child components

---

## Implementation Progress

| Step | Status | Notes |
|------|--------|-------|
| 1. usePanGesture Hook | ✅ Complete | 17 unit tests passing |
| 2. Timeline.tsx Viewport Integration | ✅ Complete | Viewport-relative rendering |
| 3. Data Filtering | ✅ Complete | visibleRegions/Markers/Items wired |
| 4. Navigate Mode Gesture Change | ✅ Complete | Pan mode default, selection toggle state |
| 5. UI Integration (ZoomControls) | ✅ Complete | Overlay in bottom-right corner |
| 6. UI Integration (SelectionToggle) | ✅ Complete | Crosshair icon button |
| 7. E2E Tests | 🔲 Pending | |

---

## Overview

This document details the exact changes needed to integrate the viewport-aware timeline into the existing frontend codebase. All code locations reference the current implementation.

### Goals
1. ✅ Add viewport state management to Timeline.tsx
2. ✅ Change navigate mode drag from "time selection" to "pan viewport"
3. ✅ Filter regions/markers/items to visible viewport for rendering
4. ✅ Integrate ZoomControls into the UI

---

## File Change Summary

| File | Type | Status | Changes |
|------|------|--------|---------|
| `Timeline.tsx` | Modify | ✅ Done | Viewport hook, pan gesture, filtered data |
| `TimelineRegions.tsx` | Modify | ✅ Done | Receives pre-filtered regions |
| `TimelineMarkers.tsx` | Modify | ✅ Done | Receives pre-filtered markers |
| `ItemDensityBlobs.tsx` | Modify | ✅ Done | Uses viewport bounds |
| `hooks/usePanGesture.ts` | Create | ✅ Done | Pan gesture with 17 unit tests |
| `TimelineHeader.tsx` | Create | 🔲 Pending | Zoom controls + mode toggle |
| `SelectionToggle.tsx` | Create | 🔲 Pending | Toggle pan/selection mode |

---

## 1. Timeline.tsx Changes

**File:** `frontend/src/components/Timeline/Timeline.tsx` (710 lines)

### 1.1 Add Viewport State

**Location:** After existing store selectors (line ~70)

```typescript
// Add import at top
import { useViewport, useVisibleRegions, useVisibleMarkers, useVisibleMediaItems } from '../../hooks';

// Add after store selectors (line ~70)
const {
  visibleRange,
  visibleDuration,
  zoomLevel,
  pan,
  zoomIn,
  zoomOut,
  setVisibleRange,
  fitToContent,
  timeToPercent: viewportTimeToPercent,
  isInView,
} = useViewport({
  projectDuration: duration,
  initialRange: { start: 0, end: 30 }, // Default 30 seconds
});
```

### 1.2 Replace Time-to-Percent Calculation

**Current location:** Lines 152-158, 257-263

The existing `timeToPercent` uses full timeline bounds. We need to use viewport-relative positioning.

**Strategy:** Keep existing `timeToPercent` for internal calculations, create `renderTimeToPercent` based on viewport:

```typescript
// NEW: Viewport-relative positioning (replaces lines 257-263)
const renderTimeToPercent = useCallback(
  (time: number) => {
    // During drag operations, extend viewport to include drag targets
    const effectiveStart = Math.min(
      visibleRange.start,
      resizeEdgePosition ?? Infinity,
      insertionPoint ?? Infinity
    );
    const effectiveEnd = Math.max(
      visibleRange.end,
      resizeEdgePosition ?? -Infinity,
      insertionPoint ?? -Infinity,
      dragCurrentTime ?? -Infinity
    );
    const effectiveDuration = effectiveEnd - effectiveStart;

    if (effectiveDuration === 0) return 0;
    return ((time - effectiveStart) / effectiveDuration) * 100;
  },
  [visibleRange, resizeEdgePosition, insertionPoint, dragCurrentTime]
);
```

### 1.3 Filter Data for Child Components

**Location:** Before child component render (line ~470)

```typescript
// Filter to visible range with buffer
const visibleRegionsResult = useVisibleRegions(displayRegions, visibleRange, 10);
const visibleMarkersResult = useVisibleMarkers(markers, visibleRange, 10);
const visibleItemsResult = useVisibleMediaItems(items, visibleRange, 10);

// Use filtered arrays for rendering
const visibleRegions = visibleRegionsResult.visibleItems;
const visibleMarkers = visibleMarkersResult.visibleItems;
const visibleItems = visibleItemsResult.visibleItems;
```

**Update child component props** (lines 475-550):

```typescript
// TimelineRegionLabels (was displayRegions)
<TimelineRegionLabels
  displayRegions={visibleRegions}
  // ... other props unchanged
/>

// TimelineMarkerLines (was markers)
<TimelineMarkerLines
  markers={visibleMarkers}
  // ... other props unchanged
/>

// ItemsDensityOverlay
<ItemsDensityOverlay
  items={visibleItems}
  timelineStart={visibleRange.start}
  timelineEnd={visibleRange.end}
  // ... other props unchanged
/>
```

### 1.4 Snap Target Pre-computation

**Issue:** Current snap calculation (lines 287-296) iterates ALL regions/markers. For viewport-aware timeline, we should pre-compute snap targets when viewport changes.

**Solution:** Compute snap candidates from visible range + 100% buffer:

```typescript
// Pre-compute snap candidates when viewport changes
const snapCandidates = useMemo(() => {
  const buffer = visibleDuration; // 100% buffer on each side
  const bufferedStart = visibleRange.start - buffer;
  const bufferedEnd = visibleRange.end + buffer;

  const candidates: number[] = [];

  // Add region boundaries
  for (const region of regions) {
    if (region.start >= bufferedStart && region.start <= bufferedEnd) {
      candidates.push(region.start);
    }
    if (region.end >= bufferedStart && region.end <= bufferedEnd) {
      candidates.push(region.end);
    }
  }

  // Add marker positions
  for (const marker of markers) {
    if (marker.position >= bufferedStart && marker.position <= bufferedEnd) {
      candidates.push(marker.position);
    }
  }

  return candidates.sort((a, b) => a - b);
}, [regions, markers, visibleRange, visibleDuration]);

// Use in snap function (update findNearestBoundary)
const findNearestBoundary = useCallback(
  (time: number): number => {
    // Binary search through pre-computed candidates
    // ... implementation
  },
  [snapCandidates]
);
```

### 1.5 Change Navigate Mode Gestures

**Current behavior (lines 298-413):**
- Drag = create time selection
- Tap = seek to nearest boundary

**New behavior:**
- Drag = pan viewport (in pan mode, default)
- Drag = create time selection (in selection mode, toggle)
- Double-tap = snap to nearest marker/region
- Tap = no action (or show playhead position)

**Changes needed:**

1. Add selection mode state:
```typescript
// Add to local state (after line 112)
const [selectionModeActive, setSelectionModeActive] = useState(false);
```

2. Create new pan gesture handler hook (see Section 5)

3. Modify handlePointerDown/Move/Up (lines 299-413):
```typescript
const handlePointerDown = useCallback((e: React.PointerEvent) => {
  if (timelineMode === 'regions') {
    // Existing region drag logic
    return;
  }

  if (timelineMode === 'navigate') {
    if (selectionModeActive) {
      // Existing time selection logic (current lines 300-320)
      // ...
    } else {
      // New: Start pan gesture
      panGesture.handlePointerDown(e);
    }
  }
}, [timelineMode, selectionModeActive, panGesture, /* ... */]);
```

---

## 2. usePanGesture Hook

**New file:** `frontend/src/components/Timeline/hooks/usePanGesture.ts`

This hook follows the pattern from useRegionDrag.ts and usePlayheadDrag.ts.

```typescript
/**
 * Pan gesture hook for viewport navigation
 * Follows existing gesture patterns: pointer capture, vertical cancel, coordinate conversion
 */

import { useCallback, useRef, useState } from 'react';
import type { TimeRange } from '../../../hooks/useViewport';

// Match existing thresholds
const VERTICAL_CANCEL_THRESHOLD = 50;

export interface UsePanGestureOptions {
  containerRef: React.RefObject<HTMLDivElement>;
  visibleRange: TimeRange;
  visibleDuration: number;
  onPan: (deltaSeconds: number) => void;
  disabled?: boolean;
}

export interface UsePanGestureResult {
  isPanning: boolean;
  handlePointerDown: (e: React.PointerEvent) => void;
  handlePointerMove: (e: React.PointerEvent) => void;
  handlePointerUp: (e: React.PointerEvent) => void;
}

export function usePanGesture({
  containerRef,
  visibleRange,
  visibleDuration,
  onPan,
  disabled = false,
}: UsePanGestureOptions): UsePanGestureResult {
  const [isPanning, setIsPanning] = useState(false);
  const dragStartXRef = useRef<number | null>(null);
  const dragStartYRef = useRef<number | null>(null);
  const lastClientXRef = useRef<number | null>(null);
  const isCancelledRef = useRef(false);

  const handlePointerDown = useCallback((e: React.PointerEvent) => {
    if (disabled || !containerRef.current) return;

    // Capture pointer for tracking outside element
    (e.target as HTMLElement).setPointerCapture(e.pointerId);

    dragStartXRef.current = e.clientX;
    dragStartYRef.current = e.clientY;
    lastClientXRef.current = e.clientX;
    isCancelledRef.current = false;
    setIsPanning(true);
  }, [disabled, containerRef]);

  const handlePointerMove = useCallback((e: React.PointerEvent) => {
    if (!isPanning || !containerRef.current) return;
    if (dragStartYRef.current === null || lastClientXRef.current === null) return;

    // Check vertical cancel
    const deltaY = Math.abs(e.clientY - dragStartYRef.current);
    const rect = containerRef.current.getBoundingClientRect();
    const isOutsideVertically =
      e.clientY < rect.top - VERTICAL_CANCEL_THRESHOLD ||
      e.clientY > rect.bottom + VERTICAL_CANCEL_THRESHOLD;

    if (isOutsideVertically || deltaY > VERTICAL_CANCEL_THRESHOLD) {
      isCancelledRef.current = true;
      return;
    }

    // Calculate pan delta
    const deltaX = e.clientX - lastClientXRef.current;
    lastClientXRef.current = e.clientX;

    // Convert pixel delta to time delta
    // Negative because dragging right = moving backward in time (earlier content comes into view)
    const timeDelta = -(deltaX / rect.width) * visibleDuration;

    onPan(timeDelta);
  }, [isPanning, containerRef, visibleDuration, onPan]);

  const handlePointerUp = useCallback((e: React.PointerEvent) => {
    if (!isPanning) return;

    // Release pointer capture
    try {
      (e.target as HTMLElement).releasePointerCapture(e.pointerId);
    } catch {
      // Already released
    }

    // Reset state
    dragStartXRef.current = null;
    dragStartYRef.current = null;
    lastClientXRef.current = null;
    isCancelledRef.current = false;
    setIsPanning(false);
  }, [isPanning]);

  return {
    isPanning,
    handlePointerDown,
    handlePointerMove,
    handlePointerUp,
  };
}
```

---

## 3. TimelineRegions.tsx Changes

**File:** `frontend/src/components/Timeline/TimelineRegions.tsx`

**Minimal changes needed.** The component already receives `displayRegions` as props. Timeline.tsx will pass pre-filtered `visibleRegions` instead.

### Only change: Key prop stability

Ensure keys remain stable when filtering. Current implementation uses `region.id` which is correct:
- Line 50: `key={`label-${regionId}`}`
- Line 127: `key={`block-${regionId}`}`

No changes needed - already using stable IDs.

---

## 4. TimelineMarkers.tsx Changes

**File:** `frontend/src/components/Timeline/TimelineMarkers.tsx`

**Minimal changes needed.** Similar to TimelineRegions - already receives markers via props.

### Only consideration: Marker at viewport edge

When a marker is exactly at the viewport boundary, it should still render. The `useVisibleMarkers` hook includes items at exact boundaries (line 87 in useVisibleItems.ts: `start >= effectiveStart && start <= effectiveEnd`).

No changes needed.

---

## 5. ItemDensityBlobs.tsx Changes

**File:** `frontend/src/components/Timeline/ItemDensityBlobs.tsx`

### 5.1 Update Props Interface

```typescript
// Current (lines 16-27)
export interface ItemsDensityOverlayProps {
  items: WSItem[];
  timelineStart: number;
  timelineEnd: number;
  height: number;
  tracks: Record<number, Track>;
}

// Keep same interface - Timeline.tsx will pass viewport bounds as timelineStart/End
```

### 5.2 Remove Manual Clipping

**Current code (lines 112-128):** Manually clips blocks to timeline bounds.

With pre-filtered items from `useVisibleMediaItems`, this clipping is redundant but harmless. Could simplify:

```typescript
// Lines 112-128 can be simplified since items are already filtered
const getBlockStyle = useCallback(
  (block: ItemRange) => {
    const duration = timelineEnd - timelineStart;
    if (duration === 0) return null;

    return {
      leftPercent: ((block.start - timelineStart) / duration) * 100,
      widthPercent: ((block.end - block.start) / duration) * 100,
    };
  },
  [timelineStart, timelineEnd]
);
```

---

## 6. ZoomControls Integration

### 6.1 Option A: Add to TimelineModeToggle

**File:** `frontend/src/components/Timeline/TimelineModeToggle.tsx`

Add ZoomControls next to mode toggle buttons:

```typescript
import { ZoomControls } from './ZoomControls';

export interface TimelineModeToggleProps {
  // New props for zoom
  zoomLevel: number;
  visibleDuration: number;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onFitToContent?: () => void;
}

export function TimelineModeToggle({
  zoomLevel,
  visibleDuration,
  onZoomIn,
  onZoomOut,
  onFitToContent,
}: TimelineModeToggleProps): ReactElement {
  // ... existing code ...

  return (
    <div className="flex items-center gap-3">
      {/* Existing mode toggle */}
      <div className="flex rounded-lg overflow-hidden border border-border-default">
        {/* ... mode buttons ... */}
      </div>

      {/* New: Zoom controls */}
      <ZoomControls
        zoomLevel={zoomLevel}
        visibleDuration={visibleDuration}
        onZoomIn={onZoomIn}
        onZoomOut={onZoomOut}
        onFitToContent={onFitToContent}
      />
    </div>
  );
}
```

### 6.2 Option B: Create TimelineHeader Component

Better separation of concerns. New file:

**File:** `frontend/src/components/Timeline/TimelineHeader.tsx`

```typescript
import { type ReactElement } from 'react';
import { TimelineModeToggle } from './TimelineModeToggle';
import { ZoomControls } from './ZoomControls';

export interface TimelineHeaderProps {
  zoomLevel: number;
  visibleDuration: number;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onFitToContent?: () => void;
}

export function TimelineHeader({
  zoomLevel,
  visibleDuration,
  onZoomIn,
  onZoomOut,
  onFitToContent,
}: TimelineHeaderProps): ReactElement {
  return (
    <div className="flex items-center justify-between px-4 py-2 border-b border-border-default">
      <TimelineModeToggle />
      <ZoomControls
        zoomLevel={zoomLevel}
        visibleDuration={visibleDuration}
        onZoomIn={onZoomIn}
        onZoomOut={onZoomOut}
        onFitToContent={onFitToContent}
      />
    </div>
  );
}
```

---

## 7. Selection Mode Toggle

### 7.1 Current State
No SelectionButton.tsx exists. Need to create it or add to existing actions.

### 7.2 Implementation

**File:** `frontend/src/components/Actions/SelectionToggle.tsx`

```typescript
import { type ReactElement, useCallback, useState } from 'react';
import { Crosshair } from 'lucide-react';
import { useLongPress } from '../../hooks';

export interface SelectionToggleProps {
  isActive: boolean;
  onToggle: () => void;
  onLongPress?: () => void;  // Opens manual selection entry
  disabled?: boolean;
}

export function SelectionToggle({
  isActive,
  onToggle,
  onLongPress,
  disabled = false,
}: SelectionToggleProps): ReactElement {
  const longPressHandlers = useLongPress({
    onTap: onToggle,
    onLongPress,
    duration: 500,
  });

  return (
    <button
      {...longPressHandlers}
      disabled={disabled}
      aria-pressed={isActive}
      className={`p-2 rounded-lg transition-colors ${
        isActive
          ? 'bg-primary text-text-on-primary'
          : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
      } ${disabled ? 'opacity-50 cursor-not-allowed' : ''}`}
      title={isActive ? 'Exit selection mode' : 'Enter selection mode (long-press for manual entry)'}
    >
      <Crosshair size={20} />
    </button>
  );
}
```

### 7.3 State Location

Selection mode state could live in:
1. **Timeline.tsx local state** - simplest, only used in Timeline
2. **Zustand store** - if needed elsewhere (e.g., keyboard shortcuts)

Recommend: Start with local state in Timeline.tsx, promote to store if needed.

---

## 8. Implementation Order

### Step 1: usePanGesture Hook ✅
- ✅ Created `hooks/usePanGesture.ts`
- ✅ Added tests `hooks/usePanGesture.test.ts` (17 tests)
- ✅ Follows existing patterns: pointer capture, vertical cancel (50px)

### Step 2: Timeline.tsx Viewport Integration ✅
- ✅ Added useViewport hook with initialRange: `{ start: 0, end: min(30, duration) }`
- ✅ Added viewport-relative `renderTimeToPercent` using `viewport.visibleRange`
- 🔲 Snap candidate pre-computation (optional optimization, deferred)

### Step 3: Data Filtering ✅
- ✅ Added useVisibleRegions/Markers/MediaItems calls
- ✅ Passed filtered data to child components
- ✅ Updated ItemDensityBlobs with `viewport.visibleRange.start/end`
- ✅ VISIBILITY_BUFFER = 10 seconds for smooth scrolling

### Step 4: Navigate Mode Gesture Change ✅
- ✅ Added `selectionModeActive` state (defaults to false = pan mode)
- ✅ Wired usePanGesture to navigate mode (pan when not in selection mode)
- ✅ Time selection preserved behind toggle

### Step 5: UI Integration ✅
- ✅ Added ZoomControls overlay in bottom-right corner of timeline
- ✅ Added SelectionToggle button (Crosshair icon) for pan/selection mode
- ✅ Wired to viewport.zoomIn/zoomOut/fitToContent and selectionModeActive state

### Step 6: Testing
- ✅ Unit tests for usePanGesture (17 tests)
- 🔲 Update E2E tests for new gestures
- 🔲 Add timeline-viewport.spec.ts

---

## 9. Key Patterns to Preserve

### 9.1 ID-Based References
All region/marker references use `.id` (REAPER's markrgnidx), never array indices:
- `selectedRegionIds: Set<number>` (Timeline.tsx line 101)
- `draggedRegionId: number | null` (regionEditSlice)
- `key={`region-${region.id}`}` (TimelineRegions.tsx)

### 9.2 Pointer Capture
All drag hooks use pointer capture pattern:
```typescript
(e.target as HTMLElement).setPointerCapture(e.pointerId);
// ... later ...
(e.target as HTMLElement).releasePointerCapture(e.pointerId);
```

### 9.3 Vertical Cancel
50px threshold for all drag operations (lines 19-22 in useRegionDrag.ts).

### 9.4 Coordinate Conversion
Consistent pattern across all hooks:
- `clientX → percent → time` for input
- `time → percent` for rendering

---

## 10. Risk Mitigations

### 10.1 Region Drag Across Viewport Edge
**Problem:** User might drag a region edge outside the current viewport.

**Solution:** During active drag (when `dragType !== 'none'`), extend effective viewport to include drag targets. Already handled in `renderTimeToPercent` modification.

### 10.2 Snap to Hidden Elements
**Problem:** Snap targets outside viewport won't work.

**Solution:** Pre-compute snap candidates from visible range + 100% buffer. Binary search during drag for O(log n) performance.

### 10.3 Performance During Rapid Pan
**Problem:** Filtering on every frame during pan could be slow.

**Solution:** useVisibleItems already memoizes based on range. Consider adding debounced filtering if needed, but start without.

### 10.4 Mode Confusion
**Problem:** User might not know if they're in pan vs selection mode.

**Solution:** Clear visual indicator on SelectionToggle button. Consider haptic feedback (navigator.vibrate) on mode change.

---

## 11. Files Reference

### Existing Files to Modify
| File | Lines of Interest |
|------|------------------|
| `Timeline.tsx` | 70 (store selectors), 152-158 (timeToPercent), 257-263 (renderTimeToPercent), 287-296 (snap), 298-413 (navigate gestures), 475-550 (child components) |
| `TimelineModeToggle.tsx` | 53-97 (mode buttons) - add zoom controls props |
| `ItemDensityBlobs.tsx` | 112-128 (clipping logic) - simplify |

### New Files to Create
| File | Purpose |
|------|---------|
| `hooks/usePanGesture.ts` | Pan gesture for navigate mode |
| `hooks/usePanGesture.test.ts` | Unit tests |
| `SelectionToggle.tsx` | Toggle button for pan/selection mode |
| `TimelineHeader.tsx` | Optional: Combined header with mode toggle + zoom |

### Already Created (Phase 1)
| File | Status |
|------|--------|
| `hooks/useViewport.ts` | ✅ Complete |
| `hooks/useViewport.test.ts` | ✅ Complete |
| `hooks/useVisibleItems.ts` | ✅ Complete |
| `hooks/useVisibleItems.test.ts` | ✅ Complete |
| `ZoomControls.tsx` | ✅ Complete |

---

## 12. Testing Checklist

### Unit Tests
- [x] usePanGesture: pointer capture, delta calculation, vertical cancel (17 tests)
- [ ] Snap candidate pre-computation: binary search, boundary handling (deferred)
- [ ] SelectionToggle: toggle state, long-press detection

### Integration Tests
- [x] Viewport state persists across component updates
- [x] Filtered data updates correctly on pan/zoom
- [ ] Drag operations work across viewport boundaries

### E2E Tests (timeline-viewport.spec.ts)
- [ ] Drag-to-pan moves viewport
- [ ] Zoom in/out changes visible duration
- [ ] Double-tap snaps to marker/region
- [ ] Selection toggle enables time selection
- [ ] Long-press on selection toggle opens dialog
- [ ] Regions/markers render only when visible
