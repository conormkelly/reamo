# Phase 5: Testing, Accessibility & LOD Implementation

**Status:** Complete
**Prerequisites:** Phases 1-4 complete (viewport hooks, backend broadcast, frontend integration, UI controls)
**Scope:** E2E tests, accessibility (prefers-reduced-motion), zoom-dependent detail rendering (LOD)

---

## Implementation Progress

| Step | Status | Notes |
|------|--------|-------|
| 1. Data Attributes for E2E | ✅ Done | Added to Timeline.tsx container |
| 2. E2E Test Infrastructure | ✅ Done | timeline-viewport.spec.ts created |
| 3. Pan Gesture E2E Tests | ✅ Done | Included in spec file |
| 4. Zoom E2E Tests | ✅ Done | Included in spec file |
| 5. Selection Toggle E2E Tests | ✅ Done | Included in spec file |
| 6. prefers-reduced-motion CSS | ✅ Done | Already existed in index.css |
| 7. useReducedMotion Hook | ✅ Done | Created with SSR safety |
| 8. LOD: useMarkerClusters Hook | ✅ Done | 40px merge threshold |
| 9. LOD: MarkerCluster Component | ✅ Done | Badge + dashed line variants |
| 10. LOD: TimelineMarkers Integration | ✅ Done | Clustered rendering + tap handler |
| 11. Follow Playhead Toggle | ✅ Done | Button in timeline header |
| 12. Follow Playhead Preference | ✅ Done | Re-enable on playback start setting |
| 13. Edge Scroll for Drag | ✅ Done | useEdgeScroll hook with time acceleration |
| 14. Unit Tests | ✅ Done | useReducedMotion (7) + useMarkerClusters (16) |

---

## File Change Summary

| File | Type | Status | Changes |
|------|------|--------|---------|
| `Timeline.tsx` | Modify | ✅ Done | data-* attrs, clustering, follow playhead, edge scroll |
| `timeline-viewport.spec.ts` | Create | ✅ Done | E2E tests for viewport interactions |
| `index.css` | Modify | ✅ Done | prefers-reduced-motion already present |
| `useReducedMotion.ts` | Create | ✅ Done | Hook for motion preference detection |
| `useMarkerClusters.ts` | Create | ✅ Done | 40px merge threshold clustering |
| `MarkerCluster.tsx` | Create | ✅ Done | Clustered marker component |
| `TimelineMarkers.tsx` | Modify | ✅ Done | Added ClusteredMarkerLines/Pills |
| `uiPreferencesSlice.ts` | Modify | ✅ Done | followPlayheadReEnable preference |
| `hooks/index.ts` | Modify | ✅ Done | Export new hooks |
| `useEdgeScroll.ts` | Create | ✅ Done | Edge scroll during playhead/marker drag |
| `useReducedMotion.test.ts` | Create | ✅ Done | Unit tests (7 tests) |
| `useMarkerClusters.test.ts` | Create | ✅ Done | Unit tests (16 tests) |

---

## Research Decisions (Incorporated)

### E2E Testing: Data Attributes

Use `data-*` attributes for testable viewport state (NOT global store promotion):

```tsx
<div
  data-testid="timeline-canvas"
  data-scroll-x={viewport.visibleRange.start}
  data-zoom-level={viewport.zoomLevel}
  data-visible-range={`${viewport.visibleRange.start}-${viewport.visibleRange.end}`}
>
```

### Reduced Motion Behavior

| Animation | Normal | Reduced Motion |
|-----------|--------|----------------|
| Playhead during playback | Smooth | **Keep** (essential) |
| Momentum scrolling | Deceleration | **Instant stop** |
| Zoom animation | 250ms ease | **Instant snap** |
| Scroll-to-playhead | Smooth | **Instant jump** |
| Cluster expand | Spring | **Instant or fade** |

### Marker Clustering: Graduated Behavior

- ≤5 markers → Popover with tappable list
- >5 markers → Zoom to expand
- At max zoom → Scrollable popover

### Follow Playhead Mode

- **Button location:** Timeline header (near zoom controls)
- **Re-enable:** User preference (setting for "on playback start" vs "explicit only")
- **Pause triggers:** Pan gesture, timeline tap, marker tap, drag selection
- **Zoom does NOT disable follow**

---

## Implementation Deviations & Learnings

### D1. Follow Playhead Requires Animation Engine, NOT Store

**Problem:** Follow playhead didn't scroll during playback - only on play/pause/seek.

**Root Cause:** The initial implementation used `positionSeconds` from the Zustand store, which only updates on transport state changes (play/pause/stop/seek). During playback, position updates come via `transportTick` events at ~30Hz, which update the `TransportAnimationEngine` but NOT the store.

**Fix:** Replace the store-based `useEffect` with `useTransportAnimation` subscription:

```tsx
// WRONG: positionSeconds only updates on state changes
useEffect(() => {
  if (!followPlayhead || !isPlaying) return;
  const playheadPos = positionSeconds; // Never changes during playback!
  // ... threshold check and pan
}, [followPlayhead, isPlaying, positionSeconds, viewport]);

// CORRECT: Animation engine provides 60fps position during playback
useTransportAnimation(
  (state) => {
    if (!followPlayhead || !state.isPlaying) return;
    // Throttle to avoid 60 viewport updates/sec
    const now = performance.now();
    if (now - lastFollowPanRef.current < 100) return;
    // ... threshold check and pan
  },
  [followPlayhead, viewport]
);
```

**Key Insight:** The store holds "state change" data (what changed), while the animation engine holds "live" data (current position). For anything that needs to track position during playback, use `useTransportAnimation`.

### D2. Viewport Bounds Must Extend During Playback (Soft-End)

**Problem:** When playing past the last region/marker (project "end"), playhead went offscreen. The viewport couldn't scroll further because it was clamped to `projectDuration`.

**Root Cause:**
- `baseDuration` is calculated from regions/markers/items + `positionSeconds`
- `positionSeconds` (store) doesn't update during playback
- `useViewport` clamps all ranges to `projectDuration`
- So viewport can't extend past the "end" during playback

**Fix:** Track maximum playhead position reached and include it in bounds calculation:

```tsx
// Track max position reached during playback (like REAPER's soft-end)
const [maxPlayheadPosition, setMaxPlayheadPosition] = useState(0);

// In animation callback:
if (state.isPlaying && playheadPos > maxPlayheadPosition) {
  setMaxPlayheadPosition(playheadPos);
}

// In baseDuration memo:
if (maxPlayheadPosition > end) end = maxPlayheadPosition;
```

**Key Insight:** REAPER has a "soft end" - the project extends as you play past it. The web UI needs to mirror this by dynamically extending bounds during playback.

### D3. Marker Navigation Requires Jump Detection

**Problem:** "Go to next marker" button seeks playhead, but viewport didn't follow (when stopped).

**Root Cause:** The animation callback only ran follow logic when `state.isPlaying`. When stopped, position changes from seeks/marker nav were ignored.

**Fix:** Detect "jumps" (position changes > 0.5s) and process them even when stopped:

```tsx
const positionDelta = Math.abs(playheadPos - lastKnownPositionRef.current);
const isJump = positionDelta > 0.5; // JUMP_THRESHOLD
lastKnownPositionRef.current = playheadPos;

// When stopped: only respond to jumps
// When playing: use threshold-based smooth follow
if (!state.isPlaying && !isJump) return;
```

### D4. Edge Scrolling for Playhead/Marker Drag

**Feature:** When dragging playhead or markers to the edge of the timeline container, the viewport automatically scrolls in that direction.

**Implementation:** Created `useEdgeScroll` hook in `frontend/src/components/Timeline/hooks/useEdgeScroll.ts`:

- **Edge zone:** 50px from container edge triggers scrolling
- **Depth-based speed:** Deeper into edge zone = faster scroll (up to 2x)
- **Time-based acceleration:** Speed ramps from 1x to 4x over 2 seconds (ease-in curve)
- **Duration scaling:** Scroll faster when zoomed out (proportional to visible duration)

**Key Pattern - Refs for Stale Closure Avoidance:**

```tsx
// Props stored in refs to avoid stale closures in RAF loop
const enabledRef = useRef(enabled);
const onPanRef = useRef(onPan);

useEffect(() => { enabledRef.current = enabled; }, [enabled]);
useEffect(() => { onPanRef.current = onPan; }, [onPan]);

// RAF loop reads from refs (always current)
const tick = useCallback((timestamp: number) => {
  if (!enabledRef.current) return; // Current value, not stale
  onPanRef.current(deltaSeconds);   // Current callback
  // ...
}, []); // No dependencies - reads from refs
```

**Integration in Timeline.tsx:**

```tsx
const edgeScroll = useEdgeScroll({
  containerRef,
  visibleDuration: viewport.visibleDuration,
  onPan: viewport.pan,
  enabled: isDraggingPlayhead || isDraggingMarker,
});

// Wrap handlers to include edge scroll
const handlePlayheadPointerMoveWithEdge = useCallback(
  (e: React.PointerEvent) => {
    handlePlayheadPointerMove(e);
    edgeScroll.updateEdgeScroll(e.clientX);
  },
  [handlePlayheadPointerMove, edgeScroll]
);
```

**Preview Rendering Fix:** Drag previews now use viewport-relative positioning:

```tsx
// Convert absolute time to viewport-relative percent for display
playheadPreviewPercent={playheadPreviewTime !== null
  ? renderTimeToPercent(playheadPreviewTime)
  : null}
```

---

## 1. Data Attributes for E2E Testing

**File:** `frontend/src/components/Timeline/Timeline.tsx`

**Location:** Main container div (around line 470)

```typescript
// Find the timeline container div and add data attributes
<div
  ref={timelineRef}
  data-testid="timeline-canvas"
  data-scroll-x={viewport.visibleRange.start.toFixed(2)}
  data-zoom-level={viewport.zoomLevel}
  data-visible-duration={viewport.visibleDuration.toFixed(2)}
  data-selection-mode={selectionModeActive}
  className={/* existing classes */}
  // ... existing props
>
```

---

## 2. E2E Test Infrastructure

**File:** `frontend/e2e/timeline-viewport.spec.ts`

```typescript
import { test, expect, Page } from '@playwright/test';

// ============================================
// Test Helpers
// ============================================

async function setupViewportTest(page: Page) {
  await page.waitForFunction(
    () => (window as any).__REAPER_STORE__ !== undefined,
    { timeout: 10000 }
  );

  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.getState()._setTestMode(true);
  });

  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.setState({
      connected: true,
      duration: 120,
      regions: [
        { id: 0, name: 'Intro', start: 0, end: 15, color: 0xff0000 },
        { id: 1, name: 'Verse', start: 15, end: 45, color: 0x00ff00 },
        { id: 2, name: 'Chorus', start: 45, end: 75, color: 0x0000ff },
        { id: 3, name: 'Bridge', start: 75, end: 90, color: 0xffff00 },
        { id: 4, name: 'Outro', start: 90, end: 120, color: 0xff00ff },
      ],
      markers: [
        { id: 0, name: 'Start', position: 0, color: 0xffffff },
        { id: 1, name: 'Drop', position: 45, color: 0xffffff },
        { id: 2, name: 'End', position: 120, color: 0xffffff },
      ],
      timelineMode: 'navigate',
    });
  });

  await page.waitForTimeout(100);
}

async function getTimeline(page: Page) {
  return page.locator('[data-testid="timeline-canvas"]');
}

async function dragTimeline(page: Page, fromPercent: number, toPercent: number) {
  const timeline = await getTimeline(page);
  const box = await timeline.boundingBox();
  if (!box) throw new Error('Timeline not found');

  const startX = box.x + (box.width * fromPercent) / 100;
  const endX = box.x + (box.width * toPercent) / 100;
  const y = box.y + box.height / 2;

  await page.mouse.move(startX, y);
  await page.mouse.down();
  await page.mouse.move(endX, y, { steps: 10 });
  await page.mouse.up();
}

// ============================================
// Pan Gesture Tests
// ============================================

test.describe('Viewport Pan Gestures', () => {
  test.use({ viewport: { width: 1024, height: 768 } });

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupViewportTest(page);
  });

  test('drag left pans viewport forward in time', async ({ page }) => {
    const timeline = await getTimeline(page);
    const initialScrollX = await timeline.getAttribute('data-scroll-x');

    await dragTimeline(page, 50, 25);

    const newScrollX = await timeline.getAttribute('data-scroll-x');
    expect(parseFloat(newScrollX!)).toBeGreaterThan(parseFloat(initialScrollX!));
  });

  test('drag right pans viewport backward in time', async ({ page }) => {
    // First pan forward to have room to pan back
    await dragTimeline(page, 50, 25);
    await page.waitForTimeout(50);

    const timeline = await getTimeline(page);
    const initialScrollX = await timeline.getAttribute('data-scroll-x');

    await dragTimeline(page, 50, 75);

    const newScrollX = await timeline.getAttribute('data-scroll-x');
    expect(parseFloat(newScrollX!)).toBeLessThan(parseFloat(initialScrollX!));
  });

  test('pan respects project bounds (no negative start)', async ({ page }) => {
    await dragTimeline(page, 25, 90);

    const timeline = await getTimeline(page);
    const scrollX = await timeline.getAttribute('data-scroll-x');
    expect(parseFloat(scrollX!)).toBeGreaterThanOrEqual(0);
  });

  test('vertical drag cancels pan gesture', async ({ page }) => {
    const timeline = await getTimeline(page);
    const box = await timeline.boundingBox();
    if (!box) throw new Error('Timeline not found');

    const initialScrollX = await timeline.getAttribute('data-scroll-x');

    const startX = box.x + box.width / 2;
    const startY = box.y + box.height / 2;

    await page.mouse.move(startX, startY);
    await page.mouse.down();
    await page.mouse.move(startX + 50, startY + 60, { steps: 5 });
    await page.mouse.up();

    const newScrollX = await timeline.getAttribute('data-scroll-x');
    expect(newScrollX).toBe(initialScrollX);
  });
});

// ============================================
// Zoom Tests
// ============================================

test.describe('Viewport Zoom Controls', () => {
  test.use({ viewport: { width: 1024, height: 768 } });

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupViewportTest(page);
  });

  test('zoom in decreases visible duration', async ({ page }) => {
    const timeline = await getTimeline(page);
    const initialDuration = await timeline.getAttribute('data-visible-duration');

    await page.click('[aria-label="Zoom in"]');

    const newDuration = await timeline.getAttribute('data-visible-duration');
    expect(parseFloat(newDuration!)).toBeLessThan(parseFloat(initialDuration!));
  });

  test('zoom out increases visible duration', async ({ page }) => {
    const timeline = await getTimeline(page);
    const initialDuration = await timeline.getAttribute('data-visible-duration');

    await page.click('[aria-label="Zoom out"]');

    const newDuration = await timeline.getAttribute('data-visible-duration');
    expect(parseFloat(newDuration!)).toBeGreaterThan(parseFloat(initialDuration!));
  });

  test('fit-to-content shows full project', async ({ page }) => {
    await page.click('[aria-label="Zoom in"]');
    await page.click('[aria-label="Zoom in"]');

    await page.click('[aria-label="Fit to content"]');

    const timeline = await getTimeline(page);
    const duration = await timeline.getAttribute('data-visible-duration');
    expect(parseFloat(duration!)).toBeGreaterThanOrEqual(100);
  });

  test('zoom buttons disable at limits', async ({ page }) => {
    for (let i = 0; i < 15; i++) {
      const zoomIn = page.locator('[aria-label="Zoom in"]');
      if (await zoomIn.isDisabled()) break;
      await zoomIn.click();
    }

    await expect(page.locator('[aria-label="Zoom in"]')).toBeDisabled();
  });
});

// ============================================
// Selection Mode Tests
// ============================================

test.describe('Selection Mode Toggle', () => {
  test.use({ viewport: { width: 1024, height: 768 } });

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupViewportTest(page);
  });

  test('toggle button shows correct aria-pressed state', async ({ page }) => {
    const toggle = page.locator('[data-testid="selection-toggle"]');

    await expect(toggle).toHaveAttribute('aria-pressed', 'false');

    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-pressed', 'true');

    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  });

  test('data attribute reflects selection mode state', async ({ page }) => {
    const timeline = await getTimeline(page);

    await expect(timeline).toHaveAttribute('data-selection-mode', 'false');

    await page.click('[data-testid="selection-toggle"]');

    await expect(timeline).toHaveAttribute('data-selection-mode', 'true');
  });
});

// ============================================
// Accessibility Tests
// ============================================

test.describe('Accessibility: Reduced Motion', () => {
  test('respects prefers-reduced-motion setting', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });

    await page.goto('/');
    await setupViewportTest(page);

    const animatedElement = page.locator('.animate-pulse').first();

    if (await animatedElement.count() > 0) {
      const animationDuration = await animatedElement.evaluate((el) => {
        return window.getComputedStyle(el).animationDuration;
      });

      expect(parseFloat(animationDuration)).toBeLessThan(0.1);
    }
  });
});
```

---

## 3. Accessibility: prefers-reduced-motion

### 3.1 CSS Media Query

**File:** `frontend/src/index.css`

Add at end of file:

```css
/* ============================================
   Accessibility: Reduced Motion
   ============================================ */

@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }

  .animate-pulse {
    animation: none !important;
  }

  .transition-colors,
  .transition-opacity,
  .transition-transform,
  .transition-all {
    transition: none !important;
  }
}
```

### 3.2 useReducedMotion Hook

**File:** `frontend/src/hooks/useReducedMotion.ts`

```typescript
import { useState, useEffect } from 'react';

/**
 * Hook to detect user's motion preferences.
 * Returns true if user prefers reduced motion.
 *
 * Use for runtime behavior changes (momentum, zoom animation duration).
 * CSS handles most cases via @media query.
 */
export function useReducedMotion(): boolean {
  const [prefersReducedMotion, setPrefersReducedMotion] = useState(() => {
    if (typeof window === 'undefined') return false;
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  });

  useEffect(() => {
    const mediaQuery = window.matchMedia('(prefers-reduced-motion: reduce)');

    const handleChange = (event: MediaQueryListEvent) => {
      setPrefersReducedMotion(event.matches);
    };

    mediaQuery.addEventListener('change', handleChange);

    return () => {
      mediaQuery.removeEventListener('change', handleChange);
    };
  }, []);

  return prefersReducedMotion;
}
```

### 3.3 Hook Export

**File:** `frontend/src/hooks/index.ts`

Add export:

```typescript
export { useReducedMotion } from './useReducedMotion';
```

---

## 4. LOD: Marker Clustering

### 4.1 useMarkerClusters Hook

**File:** `frontend/src/hooks/useMarkerClusters.ts`

```typescript
import { useMemo } from 'react';
import type { WSMarker } from '../core/types';
import type { TimeRange } from './useViewport';

const MERGE_THRESHOLD_PX = 40;

export interface MarkerCluster {
  id: string;
  position: number;
  markers: WSMarker[];
  count: number;
}

export interface UseMarkerClustersOptions {
  markers: WSMarker[];
  visibleRange: TimeRange;
  containerWidth: number;
}

export interface UseMarkerClustersResult {
  clusters: MarkerCluster[];
  shouldCluster: boolean;
}

export function useMarkerClusters({
  markers,
  visibleRange,
  containerWidth,
}: UseMarkerClustersOptions): UseMarkerClustersResult {
  return useMemo(() => {
    if (markers.length === 0 || containerWidth === 0) {
      return { clusters: [], shouldCluster: false };
    }

    const visibleDuration = visibleRange.end - visibleRange.start;
    if (visibleDuration === 0) {
      return { clusters: [], shouldCluster: false };
    }

    const pxPerSecond = containerWidth / visibleDuration;
    const mergeThresholdSeconds = MERGE_THRESHOLD_PX / pxPerSecond;

    const sorted = [...markers].sort((a, b) => a.position - b.position);

    const clusters: MarkerCluster[] = [];
    let currentCluster: WSMarker[] = [];
    let clusterStart = 0;

    for (const marker of sorted) {
      if (currentCluster.length === 0) {
        currentCluster = [marker];
        clusterStart = marker.position;
      } else {
        const lastMarker = currentCluster[currentCluster.length - 1];
        const gap = marker.position - lastMarker.position;

        if (gap <= mergeThresholdSeconds) {
          currentCluster.push(marker);
        } else {
          clusters.push(createCluster(currentCluster, clusterStart));
          currentCluster = [marker];
          clusterStart = marker.position;
        }
      }
    }

    if (currentCluster.length > 0) {
      clusters.push(createCluster(currentCluster, clusterStart));
    }

    const shouldCluster = clusters.some((c) => c.count > 1);

    return { clusters, shouldCluster };
  }, [markers, visibleRange, containerWidth]);
}

function createCluster(markers: WSMarker[], startPosition: number): MarkerCluster {
  const endPosition = markers[markers.length - 1].position;
  const centerPosition = (startPosition + endPosition) / 2;

  return {
    id: `cluster-${markers[0].id}-${markers.length}`,
    position: centerPosition,
    markers,
    count: markers.length,
  };
}
```

### 4.2 MarkerCluster Component

**File:** `frontend/src/components/Timeline/MarkerCluster.tsx`

```typescript
import { type ReactElement } from 'react';
import type { MarkerCluster as MarkerClusterType } from '../../hooks/useMarkerClusters';
import { reaperColorToHex } from '../../utils/color';

export interface MarkerClusterProps {
  cluster: MarkerClusterType;
  leftPercent: number;
  onClick?: (cluster: MarkerClusterType) => void;
}

export function MarkerCluster({
  cluster,
  leftPercent,
  onClick,
}: MarkerClusterProps): ReactElement {
  const isSingleMarker = cluster.count === 1;
  const marker = cluster.markers[0];

  if (isSingleMarker) {
    const color = reaperColorToHex(marker.color);
    return (
      <div
        className="absolute top-0 bottom-0 w-0.5"
        style={{ left: `${leftPercent}%`, backgroundColor: color }}
        title={marker.name}
      >
        <span className="absolute -top-5 left-1/2 -translate-x-1/2 text-xs whitespace-nowrap text-text-secondary">
          {marker.name}
        </span>
      </div>
    );
  }

  return (
    <button
      className="absolute top-0 bottom-0 flex items-center justify-center min-w-[44px] min-h-[44px]"
      style={{ left: `${leftPercent}%`, transform: 'translateX(-50%)' }}
      onClick={() => onClick?.(cluster)}
      title={`${cluster.count} markers: ${cluster.markers.map((m) => m.name).join(', ')}`}
      aria-label={`Cluster of ${cluster.count} markers`}
    >
      <div className="bg-primary/80 text-text-on-primary text-xs font-medium px-1.5 py-0.5 rounded-full min-w-[20px] text-center">
        {cluster.count}
      </div>
    </button>
  );
}
```

### 4.3 Hook Export

**File:** `frontend/src/hooks/index.ts`

Add export:

```typescript
export { useMarkerClusters, type MarkerCluster, type UseMarkerClustersResult } from './useMarkerClusters';
```

---

## 5. Follow Playhead Toggle

### 5.1 FollowPlayheadToggle Component

**File:** `frontend/src/components/Timeline/FollowPlayheadToggle.tsx`

```typescript
import { type ReactElement } from 'react';
import { Locate } from 'lucide-react';

export interface FollowPlayheadToggleProps {
  isFollowing: boolean;
  onToggle: () => void;
  disabled?: boolean;
}

export function FollowPlayheadToggle({
  isFollowing,
  onToggle,
  disabled = false,
}: FollowPlayheadToggleProps): ReactElement {
  return (
    <button
      onClick={onToggle}
      disabled={disabled}
      aria-pressed={isFollowing}
      aria-label={isFollowing ? 'Stop following playhead' : 'Follow playhead'}
      title={isFollowing ? 'Following playhead (click to stop)' : 'Click to follow playhead'}
      className={`p-1.5 rounded transition-colors ${
        isFollowing
          ? 'bg-primary text-text-on-primary'
          : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
      } ${disabled ? 'opacity-50 cursor-not-allowed' : ''}`}
    >
      <Locate size={16} />
    </button>
  );
}
```

---

## Testing Checklist

### E2E Tests (timeline-viewport.spec.ts)

- [ ] Drag left pans viewport forward
- [ ] Drag right pans viewport backward
- [ ] Vertical drag cancels pan gesture
- [ ] Pan respects project bounds
- [ ] Zoom in decreases visible duration
- [ ] Zoom out increases visible duration
- [ ] Fit-to-content shows full project
- [ ] Zoom buttons disable at limits
- [ ] Selection toggle changes aria-pressed
- [ ] data-selection-mode attribute updates
- [ ] Reduced motion disables animations

### Unit Tests

- [x] useReducedMotion detects preference
- [x] useReducedMotion responds to changes
- [x] useMarkerClusters merges within 40px
- [x] useMarkerClusters preserves single markers
- [x] useMarkerClusters handles empty array
- [x] useMarkerClusters handles edge positions

---

## Implementation Order

```
Step 1: Data Attributes
├── Add data-* attributes to Timeline.tsx container
└── Verify attributes update correctly

Step 2: E2E Test Infrastructure
├── Create timeline-viewport.spec.ts
├── Implement test helpers
└── Run initial smoke test

Step 3: E2E Tests
├── Pan gesture tests
├── Zoom control tests
├── Selection mode tests
└── Bounds checking tests

Step 4: Accessibility
├── Add prefers-reduced-motion CSS to index.css
├── Create useReducedMotion hook
├── Export from hooks/index.ts
└── Add reduced motion E2E test

Step 5: Marker Clustering
├── Create useMarkerClusters hook
├── Create MarkerCluster component
├── Export from hooks/index.ts
└── Add unit tests

Step 6: Follow Playhead (if time permits)
├── Create FollowPlayheadToggle component
├── Add to timeline header near ZoomControls
├── Wire up pause/resume logic
└── Add user preference setting
```

---

## Key Patterns to Preserve

### ID-Based References

All marker references use `.id` (REAPER's markrgnidx), never array indices.

### Pointer Capture

Follow existing pattern in usePanGesture.ts:
```typescript
(e.target as HTMLElement).setPointerCapture(e.pointerId);
```

### Vertical Cancel

50px threshold matches existing gesture hooks.

### Touch Target Size

44pt minimum per Apple HIG (already in MarkerCluster.tsx).

---

## References

- [TIMELINE_V2_OVERVIEW.md](../TIMELINE_V2_OVERVIEW.md) - Master architecture doc
- [VIEWPORT_ANALYSIS.md](../research/VIEWPORT_ANALYSIS.md) - LOD research
- [TIMELINE_SCROLL_BEHAVIOUR.md](../research/TIMELINE_SCROLL_BEHAVIOUR.md) - Follow playhead UX
- [FRONTEND_DEVELOPMENT.md](../frontend/FRONTEND_DEVELOPMENT.md) - Frontend patterns
- [PHASE3_FRONTEND_INTEGRATION.md](./PHASE3_FRONTEND_INTEGRATION.md) - Previous phase reference
