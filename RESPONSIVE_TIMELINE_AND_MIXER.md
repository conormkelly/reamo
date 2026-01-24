# Responsive Timeline & Mixer Height System

## Overview

Replace hardcoded height constants with a measurement-based system that dynamically fills available space. The goal is world-class responsiveness across all device sizes and orientations.

**Core principle:** Measure actual available space, subtract fixed overhead, use remainder for the primary interactive element (faders/timeline canvas).

**Prerequisites:** SecondaryPanel is already implemented with collapsible states (44px collapsed, 140px expanded). This plan builds on that foundation — the hook will read panel state from the existing store to account for panel height in calculations.

---

## Layout Budget System

The app is divided into discrete sections, each with a **budget** of vertical space. Content must fit within its budget — no overlap allowed.

```
┌─────────────────────────────────┐
│     ViewHeader (~44px)          │  shrink-0, fixed
├─────────────────────────────────┤
│                                 │
│     PRIMARY CONTENT             │  flex-1 (gets remaining)
│     (faders, timeline canvas)   │
│                                 │
├─────────────────────────────────┤
│     SECONDARY CONTENT           │  44-140px (collapsible)
│     (SecondaryPanel)            │
├─────────────────────────────────┤
│     Tab Bar (~44px)             │  optional via settings
├─────────────────────────────────┤
│     PersistentTransport (~80px) │  optional via settings
└─────────────────────────────────┘
```

### Budget Rules

1. **Each section gets a fixed or flex budget** — no negotiation
2. **Content must fit within its budget** — add `overflow-hidden` as safety net
3. **Primary content maximizes within its budget** — faders/canvas fill available space
4. **Padding/margins count against the budget** — must be subtracted from calculations

### Calculating Primary Content Budget

```typescript
// The primary content budget is what remains after fixed sections
// containerRef measures this automatically via flex-1 + h-full

// But internal padding reduces usable space
const usableBudget = availableHeight - CONTENT_PADDING;

// Component must fit within usable budget
const componentHeight = usableBudget - COMPONENT_OVERHEAD;
```

### Why This Matters

- **Cross-device consistency**: Same mental model works on iPhone SE and iPad Pro
- **No overlap bugs**: Each section stays in its lane
- **Predictable behavior**: Expanding SecondaryPanel shrinks primary content predictably
- **Easier debugging**: If something overflows, check if it exceeds its budget

---

## Current Problems

| View | Issue |
|------|-------|
| MixerView | `FADER_HEIGHT_COLLAPSED = 220` / `FADER_HEIGHT_EXPANDED = 140` are magic numbers |
| TimelineView | `TIMELINE_HEIGHT_PORTRAIT = 200` / `TIMELINE_HEIGHT_LANDSCAPE = 240` are magic numbers |

Neither measures actual available space - they're "values that worked on one phone."

---

## Architecture Decisions

### 1. Measurement Approach: Container-Level ResizeObserver

Single measurement point at the ViewLayout content area. Calculate available height, subtract overhead, pass down as prop.

**Rationale:** Matches existing `useResponsiveChannelCount` pattern, explicit, easy to debug.

### 2. Overhead Calculation: Hardcoded Constants

```typescript
// Strip overhead breakdown (164px total):
// - Color bar: h-2 = 8px
// - Track name: py-2 + text = ~28px
// - Pan control: ~44px + mb-1 = 48px
// - M/S buttons: ~26px + mb-1 = 30px
// - RecArm/Monitor: ~26px + mb-1 = 30px
// - Selection footer: h-4 = 16px
// - Main content pb-1: 4px
const STRIP_OVERHEAD_FULL = 164;

// Container padding (p-3 = 12px * 2 sides)
const MIXER_CONTENT_PADDING = 24;

const TIMELINE_OVERHEAD = 80;     // Ruler + markers + footer controls
```

**Rationale:** Simpler than dynamic measurement, overhead rarely changes, easy to tune. Document the breakdown so future changes can update the constant.

### 3. Constraints: Maximize with Min/Max

- **Minimum:** Touch usability floor (FINE mode handles precision)
  - Fader: 50px (enough for thumb to grab)
  - Timeline: 80px (enough to see lanes)
- **Maximum:** 70% of container height (prevents overflow in edge cases like split-screen, large keyboard)

```typescript
// Robust height calculation with floor AND ceiling
const calculated = availableHeight - overhead;
const faderHeight = Math.min(
  Math.max(MIN_FADER, calculated),     // Floor: never below minimum
  availableHeight * 0.7                 // Ceiling: never more than 70% of container
);
```

### 4. Animation: No Jank, Accessibility-Respecting

Update heights **after** panel animation completes to avoid mid-animation layout shifts.

```typescript
// Listen for transitionend on SecondaryPanel, then recalculate
// Respect prefers-reduced-motion
```

### 5. Landscape: Alternate Compact Layout

Landscape has dramatically less vertical space. Instead of cramped controls:

**Mixer Landscape Mode:**
- Show ONLY: fader + meter + selection footer
- Move pan, M/S, arm/monitor to BottomSheet (tap strip to open)
- This gives ~200px for fader vs ~80px with full controls

**Timeline Landscape Mode:**
- Collapse SecondaryPanel automatically
- Use full available height for lanes
- Controls accessible via header overflow menu

**Rationale:** User can rotate phone - they're not dumb. Better to have a great landscape experience than a cramped one.

### 6. Shared Hook: `useAvailableContentHeight`

Same hook for both Mixer and Timeline. Each view applies its own overhead constant.

```typescript
const { availableHeight, isLandscape } = useAvailableContentHeight(containerRef);
const faderHeight = Math.max(MIN_FADER_HEIGHT, availableHeight - MIXER_STRIP_OVERHEAD);
```

**Decision pending:** Verify Timeline can use same hook or needs separate calculation. Document findings during implementation.

### 7. API Design: Simple + Debuggable

```typescript
interface UseAvailableContentHeightReturn {
  /** Measured height of content area in pixels */
  availableHeight: number;
  /** Whether we're in landscape orientation */
  isLandscape: boolean;
  /** True while panel is animating (heights may be stale) */
  isTransitioning: boolean;
}
```

---

## Implementation Plan

> **Status:** All phases complete. See updated constants in `constants/layout.ts`.

### Phase 1: Create the Hook ✓

**File:** `frontend/src/hooks/useAvailableContentHeight.ts`

```typescript
/**
 * useAvailableContentHeight - Measures available height in ViewLayout content area
 *
 * Uses ResizeObserver to track container height changes. Waits for panel
 * transitions to complete before reporting new values to avoid jank.
 */

export interface UseAvailableContentHeightOptions {
  /** Ref to the content container element */
  containerRef: RefObject<HTMLElement | null>;
  /** View ID for panel state lookup */
  viewId: 'mixer' | 'timeline';
}

export interface UseAvailableContentHeightReturn {
  availableHeight: number;
  isLandscape: boolean;
  isTransitioning: boolean;
}

export function useAvailableContentHeight(
  options: UseAvailableContentHeightOptions
): UseAvailableContentHeightReturn {
  // 1. ResizeObserver on containerRef for height
  // 2. useIsLandscape() for orientation
  // 3. Listen to panel expanded state from store
  // 4. Track transition state (defer height update until transition ends)
  // 5. Return { availableHeight, isLandscape, isTransitioning }
}
```

**Key behaviors:**
- Initial measurement on mount
- Update on resize (orientation change, keyboard, etc.)
- Debounce during panel animation (200ms matches panel transition)
- Use `requestAnimationFrame` to batch with paint

**Note:** `useIsLandscape` already exists in `hooks/useMediaQuery.ts` - use it, don't recreate.

**Debug helper** (temporary, remove after tuning):
```typescript
// Add to MixerStrip temporarily to verify overhead constant
useEffect(() => {
  const strip = stripRef.current;
  const fader = faderRef.current;
  if (strip && fader) {
    console.log('Actual overhead:', strip.offsetHeight - fader.offsetHeight);
  }
}, []);
```

### Phase 2: Create Landscape Strip Component ✓

**File:** `frontend/src/components/Mixer/MixerStripCompact.tsx`

Minimal strip for landscape mode:
- **Fader + meter** (full available height) — meter included for visual feedback, zero interaction overhead
- Track name (truncated, small)
- Selection footer
- Tap anywhere on strip to open detail BottomSheet

```typescript
interface MixerStripCompactProps {
  trackIndex: number;
  faderHeight: number;
  isInfoSelected: boolean;
  onSelectForInfo: (idx: number) => void;
  onOpenDetail: (idx: number) => void; // Opens BottomSheet with full controls
}
```

**Decision:** Include meter in compact strip. Without it, landscape mode becomes "blind mixing" — user has no level feedback.

### Phase 3: Create Track Detail BottomSheet ✓

**File:** `frontend/src/components/Mixer/TrackDetailSheet.tsx`

BottomSheet containing:
- Track name + color
- Pan control
- M/S buttons
- Arm/Monitor buttons
- Routing button
- FX button

Triggered by tapping compact strip in landscape.

**Persistence behavior:** When user opens detail sheet for track 3, adjusts pan, then taps track 5:
- Sheet **stays open** and switches to track 5's controls
- Better for workflow than close-and-reopen
- Swipe down or tap outside to dismiss

```typescript
interface TrackDetailSheetProps {
  trackIndex: number | null;  // null = closed
  onClose: () => void;
  onTrackChange: (idx: number) => void;  // Called when tapping different strip while open
}
```

### Phase 4: Update MixerView ✓

**Note:** SecondaryPanel is already implemented. The hook reads `secondaryPanelExpanded.mixer` from the store to know panel height. Container measurement happens on the content area *above* the SecondaryPanel, so panel height is already excluded from `availableHeight`.

```typescript
// In MixerView.tsx

const { availableHeight, isLandscape, isTransitioning } = useAvailableContentHeight({
  containerRef,
  viewId: 'mixer',
});

// Calculate fader height
const faderHeight = useMemo(() => {
  const overhead = isLandscape ? STRIP_OVERHEAD_COMPACT : STRIP_OVERHEAD_FULL;
  const minHeight = isLandscape ? MIN_FADER_LANDSCAPE : MIN_FADER_PORTRAIT;
  return Math.max(minHeight, availableHeight - overhead);
}, [availableHeight, isLandscape]);

// Render appropriate strip component
{isLandscape ? (
  <MixerStripCompact
    trackIndex={idx}
    faderHeight={faderHeight}
    onOpenDetail={openDetailSheet}
  />
) : (
  <MixerStrip
    trackIndex={idx}
    faderHeight={faderHeight}
  />
)}
```

### Phase 5: Update TimelineView ✓

```typescript
// In TimelineView.tsx

const { availableHeight, isLandscape } = useAvailableContentHeight({
  containerRef: timelineContainerRef,
  viewId: 'timeline',
});

// Calculate timeline height
const timelineHeight = useMemo(() => {
  const overhead = TIMELINE_OVERHEAD;
  const minHeight = MIN_TIMELINE_HEIGHT;
  return Math.max(minHeight, availableHeight - overhead);
}, [availableHeight]);

// Auto-collapse panel in landscape
useEffect(() => {
  if (isLandscape) {
    setSecondaryPanelExpanded('timeline', false);
  }
}, [isLandscape]);
```

### Phase 6: Constants File ✓

**File:** `frontend/src/constants/layout.ts`

```typescript
/** Mixer strip overhead (non-fader elements) */
export const STRIP_OVERHEAD_FULL = 155;    // Full strip with all controls
export const STRIP_OVERHEAD_COMPACT = 24;  // Just selection footer

/** Minimum fader heights for touch usability */
export const MIN_FADER_PORTRAIT = 80;
export const MIN_FADER_LANDSCAPE = 50;

/** Timeline overhead (ruler, markers, footer) */
export const TIMELINE_OVERHEAD = 80;
export const MIN_TIMELINE_HEIGHT = 100;

/** Panel animation duration (match SecondaryPanel CSS) */
export const PANEL_TRANSITION_MS = 200;
```

---

## File Changes Summary

### New Files
| File | Purpose |
|------|---------|
| `hooks/useAvailableContentHeight.ts` | Measure available height with ResizeObserver |
| `components/Mixer/MixerStripCompact.tsx` | Minimal strip for landscape |
| `components/Mixer/TrackDetailSheet.tsx` | BottomSheet with full track controls |
| `constants/layout.ts` | Centralized layout constants |

### Modified Files
| File | Changes |
|------|---------|
| `views/mixer/MixerView.tsx` | Use hook, switch strip component by orientation |
| `views/timeline/TimelineView.tsx` | Use hook for timeline height |
| `components/Mixer/index.ts` | Export new components |
| `hooks/index.ts` | Export new hook |
| `constants/index.ts` | Export layout constants (create if needed) |

---

## Testing Strategy

### Unit Tests
- `useAvailableContentHeight.test.ts`: Mock ResizeObserver, verify height calculation
- `MixerStripCompact.test.tsx`: Renders correctly, fires callbacks

### E2E Tests
- Orientation change: strips resize appropriately
- Panel expand/collapse: no jank, heights update after animation
- Detail sheet: opens on tap in landscape, shows all controls

### Manual Testing Matrix
| Device | Portrait | Landscape |
|--------|----------|-----------|
| iPhone SE | Full strips fit | Compact strips + sheet |
| iPhone 15 Pro | Full strips fit | Compact strips + sheet |
| iPad Mini | Full strips fit | Full strips fit (larger) |
| iPad Pro | Full strips fit | Full strips fit |

---

## Accessibility Considerations

1. **Reduced motion:** Skip transition delays when `prefers-reduced-motion` is set
2. **Touch targets:** Minimum 44x44px on all interactive elements
3. **Screen readers:** TrackDetailSheet announces track info on open
4. **Keyboard:** Detail sheet dismissible with Escape

---

## Open Questions / Decisions During Implementation

- [x] ~~Verify Timeline overhead calculation is accurate~~ → **Updated to mode-aware constants** (TIMELINE_OVERHEAD_NAVIGATE=121px, TIMELINE_OVERHEAD_REGIONS=77px)
- [x] ~~Confirm shared hook works for both views or needs specialization~~ → **Shared hook works for both** (useAvailableContentHeight)
- [ ] Test panel transition timing across devices (may need adjustment)
- [x] ~~Decide if compact strip needs meter or just fader~~ → **Include meter** (see Phase 2 rationale)
- [ ] Consider whether Timeline also needs landscape simplification

---

## Success Criteria

- [x] No hardcoded height magic numbers in view files
- [x] Faders fill maximum available space on all devices
- [x] Landscape mode is usable and pleasant (not cramped) - MixerStripCompact + TrackDetailSheet
- [x] Panel expand/collapse has no layout jank - useAvailableContentHeight tracks transition state
- [ ] Works in iOS Safari PWA mode (safe areas handled) - needs manual testing
- [x] Orientation changes are smooth - ResizeObserver handles this
- [x] All existing functionality preserved
- [x] New patterns documented in FRONTEND_DEVELOPMENT.md - Layout Budget System §19

---

## Related Documentation

- `FRONTEND_DEVELOPMENT.md` - Add new patterns after implementation
- `docs/architecture/UX_GUIDELINES.md` - Reference for touch targets
- Research findings in conversation (fader min/max, CSS approaches)
