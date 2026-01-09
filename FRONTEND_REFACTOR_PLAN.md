# Frontend Codebase Health Plan

**Goal**: Get the frontend codebase clean, testable, and well-architected before implementing:
1. **Viewport-Aware Timeline** (virtual render, zoom detail, dynamic loading)
2. **Dedicated MixerView** (fresh build, shared primitives)

**Execution Strategy**: Sequential PRs - each phase is a mergeable PR

**Last Updated**: 2026-01-09

---

## PR 1: WebSocket State Machine Refactor

> **PENDING**: Research query sent for state machine library decision (XState vs Custom vs Zustand middleware)

**Why First**: Dynamic data loading for viewport-aware timeline depends on reliable, debuggable WebSocket handling. Current implicit state machine has race conditions and memory leak potential.

### Current Issues
- Implicit state machine across callbacks/timeouts
- 3 storage locations (class fields, hook ref, Zustand store)
- Components only see `connected: boolean`, not full state
- `pendingResponses` unbounded, resolves instead of rejects on disconnect
- Race conditions between reconnection, heartbeat, visibility change

### Target Architecture
```
States: idle → discovering → connecting → handshaking → connected → disconnected
                                                            ↑
                                            error → retrying ─┘
```

### Implementation
1. Create explicit `ConnectionState` type with all states
2. Create `ConnectionEvent` discriminated union for transitions
3. Replace callback-based transitions with state machine (xstate or custom)
4. Single source of truth in Zustand (expose full state, not just boolean)
5. Fix `pendingResponses`: bound size, proper rejection, timeout cleanup
6. Add connection state UI feedback (connecting, retrying, gave up)

### Files to Modify
- `frontend/src/core/WebSocketConnection.ts` - state machine core
- `frontend/src/hooks/useReaperConnection.ts` - simplify to thin wrapper
- `frontend/src/store/slices/connectionSlice.ts` - expose full state
- `frontend/src/components/ConnectionStatus.tsx` - new component (or enhance existing)

### Success Criteria
- [ ] All state transitions explicit and logged
- [ ] Single source of truth for connection state
- [ ] `sendAsync` properly rejects on disconnect/timeout
- [ ] Connection UI shows: connecting, connected, retrying (X/10), gave up
- [ ] Existing WebSocket tests pass + new state transition tests

---

## PR 2: Testing Infrastructure

### 2a. data-testid Migration

**Why**: Current selectors use class names (`ring-white`, `bg-primary`) which break on style changes.

**Pattern**:
```tsx
// Component
<div data-testid="region-bar" data-region-id={id} data-selected={isSelected}>

// Test
screen.getByTestId('region-bar')
container.querySelector('[data-region-id="abc"][data-selected="true"]')
```

**Files to Update**:
- `frontend/src/test/queries.ts` - update query utilities
- Components: Timeline regions, markers, track strips, modals
- E2E tests: update Playwright selectors

### 2b. Component Test Coverage

**Priority Components** (used in both Timeline and Mixer features):
1. `TrackStrip` / track controls (Fader, MuteButton, SoloButton, etc.)
2. `RegionInfoBar` / `MarkerInfoBar`
3. `Modal` system (already has tests - expand)
4. `ActionButton` / `ToggleButton` variants

**Testing Pattern**:
```typescript
describe('TrackStrip', () => {
  it('renders track name and controls', () => {});
  it('shows selected state via data-selected', () => {});
  it('calls onMute when mute button clicked', () => {});
  it('handles meter updates without re-render', () => {});
});
```

### 2c. E2E Test Cleanup

- Extract common patterns into page objects
- Add error state scenarios
- Ensure tests don't depend on timing (use waitFor patterns)

---

## PR 3: Component Architecture Cleanup

### 3a. Extract Inline Components

**From MixerSection.tsx**:
- `MasterTrackStrip` → `components/Track/MasterTrackStrip.tsx`
- `MixerLockButton` → `components/Actions/MixerLockButton.tsx`
- `UnselectAllTracksButton` → `components/Actions/UnselectAllTracksButton.tsx`

**From VirtualizedTrackList.tsx**:
- `TrackStripWithMeter` → `components/Track/TrackStripWithMeter.tsx`

### 3b. Button System Unification

**Current State** (4+ patterns):
- `ActionButton` with variants (default/primary/danger/ghost)
- `ToggleButton` with activeColor (green/blue/yellow/etc)
- Transport buttons (Play/Stop/Record) with inline ternaries
- Track buttons (Mute/Solo/Monitor) with custom isActive styling

**Target**: Unified system where all buttons compose from same primitives

```typescript
// Option A: Extend ActionButton
<ActionButton variant="toggle" active={isMuted} activeColor="yellow">
  <Volume2 />
</ActionButton>

// Option B: Composition
<ToggleButton active={isMuted} activeColor="yellow">
  <ActionButton icon={<Volume2 />} />
</ToggleButton>
```

**Decision needed**: Which pattern? (can discuss)

### 3c. Store Selector Consistency

Standardize defensive selectors with stable fallbacks:
```typescript
// All selectors should use stable refs for fallbacks
const tracks = useReaperStore((s) => s.tracks ?? EMPTY_TRACKS);
const regions = useReaperStore((s) => s.regions ?? EMPTY_REGIONS);
```

Add `EMPTY_*` constants to `stableRefs.ts` for all nullable collections.

---

## PR 4: Pre-Feature Prep

### For Viewport-Aware Timeline

**Concept**: Instead of rendering entire project at fixed zoom, show a ~30 second rolling slice that users can navigate. Backend handles heavy lifting via subscription model.

**Current State** → **Target State**:
- Now: Fetch ALL regions/markers/items, render at implicit zoom
- Target: Subscribe to visible time range, render only that slice, pan/zoom to navigate

**Architecture needs**:

1. **Viewport State Management**
   - Track: startTime, endTime, zoom level
   - Persist position across view switches
   - Handle zoom gestures (pinch on iPad)

2. **Subscription-Based Data Loading**
   - Extension API: `timeline/subscribe { startTime, endTime }`
   - Backend sends updates only for visible range
   - Debounce viewport changes to avoid subscription spam

3. **Virtual Rendering**
   - Only render regions/markers in current ~30s window
   - Need efficient "is item in viewport?" checks
   - Consider TanStack Virtual (already used for Mixer tracks)

4. **Zoom-Dependent Detail**
   - High zoom: waveforms, precise positions
   - Low zoom: density blobs (already have ItemDensityBlobs)
   - Threshold-based switching

**New hooks needed**:
- `useViewport` - track viewport bounds (startTime, endTime, zoom)
- `useTimelineSubscription` - subscribe to data for visible range
- `useVisibleItems` - filter items by viewport (memoized)

### For Dedicated MixerView

**Shared primitives** (already exist):
- `Fader`, `PanKnob`, `LevelMeter`
- `MuteButton`, `SoloButton`, `RecordArmButton`, `MonitorButton`
- Store hooks: `useTrack`, `useTracks`, `useMeterSubscription`

**New components needed**:
- `MixerChannel` - full channel strip for dedicated view (larger than TrackStrip)
- `MixerMaster` - dedicated master section
- `MixerLayout` - grid/flex layout for channels
- `MixerToolbar` - view-specific controls

**State considerations**:
- Mixer might need independent scroll position, selection
- Consider `mixerViewSlice` for view-specific state

---

## Execution Order

**START HERE → PR 2** (while WebSocket research is pending)

```
PR 2: Testing Infrastructure ← START HERE
      └── data-testid migration for regions/timeline
      └── Component tests for key primitives
      └── E2E test cleanup

PR 1: WebSocket State Machine (after research results)
      └── Implement chosen state machine pattern
      └── Fix pendingResponses issues
      └── Expose full state to components

PR 3: Component Architecture
      └── Extract inline components
      └── Button system unification (if needed)

PR 4: Pre-Feature Prep
      └── Viewport hooks design
      └── MixerView component design
      └── Extension API for range queries

Then: Feature PRs (Viewport Timeline, MixerView)
```

---

## Open Questions

1. **State machine library**: XState vs custom reducer vs Zustand middleware? (Research query prepared - awaiting results)
2. **Virtual rendering**: TanStack Virtual (already used for Mixer) vs custom for Timeline?
3. **Extension API**: What new commands needed for time-range queries?

---

## Anti-Patterns to Eliminate

| Current | Target |
|---------|--------|
| Inline component definitions | Extracted, reusable, tested |
| Class-name selectors in tests | data-testid attributes |
| Implicit WebSocket state | Explicit state machine |
| Boolean `connected` only | Full ConnectionState exposed |
| 4 button patterns | Unified button system |
| Nullable collections without fallback | Stable EMPTY_* refs everywhere |

---

## Progress Log

### 2026-01-09
- Initial plan created
- Explored codebase: component organization, WebSocket architecture, testing patterns
- Identified 4 PRs needed before major features
- Research query prepared for state machine library decision
- Starting with PR 2 (Testing Infrastructure) while research is pending

### 2026-01-09 (continued) - PR 2 Progress

**Audit completed** - Identified 40+ brittle class-based selectors across E2E tests

**data-testid additions completed:**

| Component | Attributes Added |
|-----------|-----------------|
| TimelineRegions.tsx | `data-testid="region-label"`, `data-testid="region-block"`, `data-region-id`, `data-region-name`, `data-selected`, `data-dragging`, `data-pending`, `data-new` |
| TimelinePlayhead.tsx | `data-playhead`, `data-testid="playhead"` |
| Timeline.tsx | `data-testid="time-selection"`, `data-testid="selection-preview"`, `data-testid="insertion-indicator"` |
| BarBeatDisplay.tsx | `data-testid="beats-display"` |
| TimeDisplay.tsx | `data-testid="time-display"` |
| BpmTimeSigDisplay.tsx | `data-testid="bpm-timesig-display"` |
| TransportControls.tsx | `data-testid="transport-controls"`, `data-testid="transport-button"` with `data-action` |

**test/queries.ts updated:**
- All query functions now check data attributes first, with class-based fallbacks
- New functions: `findRegionById()`, `findAllRegionBlocks()`, `findAllRegionLabels()`, `findTimeSelection()`, `findSelectionPreview()`, `findInsertionIndicator()`

**All 482 unit tests pass.**

**Remaining for PR 2:**
- [ ] TrackStrip components (for track-selection.spec.ts)
- [ ] Update E2E tests to use new data-testid selectors
- [ ] Final test verification

**Waiting for:** WebSocket state machine research results before PR 1
