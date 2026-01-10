# Frontend Codebase Health Plan

**Goal**: Get the frontend codebase clean, testable, and well-architected before implementing:
1. **Viewport-Aware Timeline** (virtual render, zoom detail, dynamic loading)
2. **Dedicated MixerView** (fresh build, shared primitives)

**Execution Strategy**: Sequential PRs - each phase is a mergeable PR

**Last Updated**: 2026-01-10

---

## PR 1: WebSocket State Machine Refactor

> **DECISION: XState v5 + @xstate/react** (~18kB gzipped, ~4.5% of remaining 400kB budget)

**Why First**: Dynamic data loading for viewport-aware timeline depends on reliable, debuggable WebSocket handling. Current implicit state machine has race conditions and memory leak potential.

### Research Summary (2026-01-09)

**Why XState over alternatives:**
- Safari/iOS zombie connection handling requires robust state management
- `fromCallback` actor cleanup + `after` transitions handle edge cases declaratively
- Deterministic testing with Vitest fake timers
- Visualization available via Stately.ai (optional, document as fallback for Safari debugging)

**Alternatives considered:**
- **robot3** (~1.2kB): Viable but requires manual timeout management
- **Custom Zustand reducer**: Works but ~150-200 lines of careful timeout code
- **@xstate/fsm**: Deprecated in v5

**Zustand integration**: Global actor with manual sync to existing store (Option 2)
- Keeps existing `useReaperStore` structure intact
- Actor is single source of truth, syncs to `connectionSlice`
- No new middleware dependency

### Current Issues
- Implicit state machine across callbacks/timeouts
- 3 storage locations (class fields, hook ref, Zustand store)
- Components only see `connected: boolean`, not full state
- `pendingResponses` unbounded, resolves instead of rejects on disconnect
- Race conditions between reconnection, heartbeat, visibility change

### Target Architecture
```
States: idle → discovering → connecting → handshaking → connected
                                                ↓ (on visibility return)
                                            verifying
                                                ↓ (on error/timeout)
                                            retrying → waiting → gave_up
                                                         ↓ (after delay)
                                                     connecting
```

**Key states:**
- `discovering`: Fetch `/_/DAT` to get WebSocket URL (failures trigger retry)
- `connecting`: WebSocket connection attempt (10s timeout for Safari CONNECTING hang)
- `handshaking`: Waiting for `hello` response (5s timeout)
- `connected`: Normal operation, heartbeat running (10s ping, 3s pong timeout per API.md)
- `verifying`: On visibility return, send ping and wait for pong (5s timeout)
- `retrying`: Increment retry count, check if can continue
- `waiting`: Exponential backoff delay before next attempt
- `gave_up`: Max retries (10) exceeded, manual retry available

**Heartbeat implementation:**
- Explicit ping/pong per API.md (not implicit transport sync)
- 10s interval when page visible
- Stop heartbeat when page hidden
- 3s pong timeout = dead connection

### Implementation Steps

1. **Install dependencies**
   ```bash
   npm install xstate @xstate/react
   ```

2. **Create WebSocket state machine**
   - `frontend/src/core/websocketMachine.ts` - XState machine definition
   - Use `fromCallback` actor for WebSocket with synthetic `CloseEvent` cleanup
   - Discovery as first state (inside machine)
   - `after` transitions for all timeouts
   - `reenter: true` on pong to reset heartbeat timer

3. **Create global actor singleton**
   - `frontend/src/core/websocketActor.ts` - creates and exports actor
   - Sync relevant state to Zustand store

4. **Update connectionSlice**
   - Expose full state (not just boolean): `{ status, retryCount, lastError }`
   - Derive `connected` for backward compatibility

5. **Fix pendingResponses**
   - Reject all pending on actor cleanup (state exit)
   - Bound size (e.g., 100 pending max)
   - Timeout per request (30s default)

6. **Simplify useReaperConnection hook**
   - Thin wrapper around actor
   - Start/stop actor on mount/unmount

7. **Add connection state UI** (optional enhancement)
   - Show: connecting, connected, retrying (X/10), gave up
   - Manual retry button in gave_up state

### Files to Modify
- `frontend/src/core/websocketMachine.ts` - **NEW** XState machine definition
- `frontend/src/core/websocketActor.ts` - **NEW** global actor singleton
- `frontend/src/core/WebSocketConnection.ts` - simplify to send/receive wrapper
- `frontend/src/hooks/useReaperConnection.ts` - thin wrapper around actor
- `frontend/src/store/slices/connectionSlice.ts` - expose full state
- `frontend/src/components/ConnectionStatus.tsx` - enhance existing or new

### Testing Strategy

```typescript
describe('WebSocket state machine', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('transitions to retrying after CONNECT_TIMEOUT', () => {
    const actor = createActor(websocketMachine);
    actor.start();
    actor.send({ type: 'START', url: 'ws://localhost' });
    // ... advance timers, assert state
  });

  it('resets retryCount on successful connection');
  it('gives up after max retries');
  it('enters verifying state on visibility return');
  it('rejects pending requests on disconnect');
});
```

### Success Criteria
- [x] All state transitions explicit and logged
- [x] Single source of truth for connection state (XState actor)
- [x] `sendAsync` properly rejects on disconnect/timeout
- [x] Connection UI shows: connecting, connected, retrying (X/10), gave up
- [x] Existing WebSocket tests pass + new state transition tests
- [x] Safari zombie detection works via ping/pong in verifying state
- [x] Heartbeat stops when page hidden, resumes on visible

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

> **See [PR3-detailed-plan.md](PR3-detailed-plan.md) for full implementation details.**

### Summary

| Task | Scope |
|------|-------|
| 3a. Extract Inline Components | 4 components from MixerSection + VirtualizedTrackList |
| 3b. Button A11y Fixes | Add `aria-pressed` to 6 toggle buttons |
| 3c. Store Selector Consistency | Already clean - no action needed |

**Decision**: Keep ActionButton and ToggleButton separate (different semantics).

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

**CURRENT: PR 4** (PRs 1-3 complete)

```
PR 1: WebSocket State Machine ✅ COMPLETE
      └── XState v5 machine with all states
      └── Global actor singleton with Zustand sync
      └── Safari/iOS fixes (zombie connections, heartbeat, visibility)
      └── Tested on Safari iOS PWA - working

PR 2: Testing Infrastructure ✅ COMPLETE
      └── data-testid migration across E2E tests
      └── 76 new unit tests (ActionButton, ToggleButton, useLongPress, ConnectionStatus)
      └── Coverage tooling (@vitest/coverage-v8)

PR 3: Component Architecture ✅ COMPLETE
      └── Extracted 4 inline components (MasterTrackStrip, TrackStripWithMeter, MixerLockButton, UnselectAllTracksButton)
      └── Added aria-pressed to 6 toggle buttons
      └── 27 new unit tests for extracted components

PR 4: Pre-Feature Prep ← NEXT
      └── Viewport hooks design
      └── MixerView component design
      └── Extension API for range queries

Then: Feature PRs (Viewport Timeline, MixerView)
```

---

## Open Questions

1. ~~**State machine library**: XState vs custom reducer vs Zustand middleware?~~ **RESOLVED: XState v5**
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

**Remaining for PR 2:** (paused, will complete after PR 1)
- [ ] TrackStrip components (for track-selection.spec.ts)
- [ ] Update E2E tests to use new data-testid selectors
- [ ] Final test verification

---

### 2026-01-09 (continued) - PR 1 Research Complete

**Research results received** - XState v5 selected as state machine library

**Key decisions:**
- **XState v5 + @xstate/react** (~18kB gzipped) - justified by Safari/iOS complexity
- **Global actor with manual Zustand sync** - keeps existing store structure
- **Discovery inside machine** - failures trigger retry like other connection errors
- **Explicit ping/pong** per API.md (10s interval, 3s timeout, stop when hidden)
- **Stately.ai visualization** - documented as optional debug tool

**Starting PR 1 implementation:**
1. Install xstate + @xstate/react
2. Create websocketMachine.ts
3. Create websocketActor.ts with store sync
4. Migrate existing WebSocketConnection.ts logic

---

### 2026-01-09 (continued) - PR 1 Implementation Complete

**Files created/modified:**

| File | Status | Description |
|------|--------|-------------|
| `frontend/src/core/websocketMachine.ts` | **NEW** | XState v5 machine with all states: idle, discovering, connecting, handshaking, connected, verifying, retrying, waiting, gave_up |
| `frontend/src/core/websocketActor.ts` | **NEW** | Global actor singleton with Zustand sync, pendingResponses management, sendCommand/sendCommandAsync API |
| `frontend/src/core/websocketMachine.test.ts` | **NEW** | 20 tests for state machine structure and transitions |
| `frontend/src/store/slices/connectionSlice.ts` | Modified | Added `connectionStatus`, `retryCount`, and corresponding setters |
| `frontend/src/hooks/useReaperConnection.ts` | Modified | Simplified to thin wrapper around wsActor |

**Key implementation details:**

1. **State machine architecture:**
   - Uses `fromCallback` actor for WebSocket with synthetic `CloseEvent` cleanup (Safari fix)
   - Uses `fromPromise` actor for discovery (EXTSTATE fetch)
   - Uses `fromCallback` actor for heartbeat with 10s ping interval
   - All timeouts via `after` transitions: CONNECT_TIMEOUT (10s), HELLO_TIMEOUT (5s), PONG_TIMEOUT (3s), VERIFY_TIMEOUT (5s)
   - Exponential backoff with jitter for reconnect delays

2. **pendingResponses fixed:**
   - Bounded to MAX_PENDING_REQUESTS (100)
   - Individual request timeout (30s default)
   - All pending rejected on disconnect/stop
   - generateMessageId() with counter for unique IDs

3. **Zustand integration:**
   - Actor subscribes to state changes and syncs to `connectionSlice`
   - Components continue using `useReaperStore` selectors
   - `connectionStatus` exposes full state machine status (not just boolean)

4. **Safari/iOS workarounds preserved:**
   - Synthetic CloseEvent dispatch in cleanup
   - CONNECTING state timeout (Safari hangs)
   - Visibility return triggers verifying state with ping/pong
   - Heartbeat stops when page hidden

**All 502 tests pass.**

**PR 1 Complete** - All items done, tested on Safari iOS PWA.

---

### 2026-01-10 - PR 2 Continued (TrackStrip Migration)

**TrackStrip data-testid migration completed:**

| Component | Attributes Added |
|-----------|-----------------|
| TrackStrip.tsx | `data-testid="track-strip"`, `data-track-index`, `data-selected`, `data-master`, `data-testid="track-name"`, `data-testid="track-color-bar"`, `data-testid="track-number"` |

**E2E test updated:**
- `track-selection.spec.ts` - All 8 tests migrated from class selectors (`.rounded-lg.border`, `.cursor-pointer`) to data-testid
- Added 2 new tests for track number display (non-master shows number, master doesn't)

**test/queries.ts updated:**
- New functions: `findTrackStrip()`, `findAllTrackStrips()`, `findMasterTrackStrip()`, `findNonMasterTrackStrips()`, `findTrackName()`, `findTrackColorBar()`, `findTrackNumber()`, `isTrackSelected()`, `isTrackMaster()`, `getTrackIndex()`

**All 503 tests pass.**

**Remaining E2E migrations (continued):**

| File | Changes |
|------|---------|
| clock-view.spec.ts | Migrated to `[data-testid="beats-display"]`, `[data-testid="time-display"]`, `[data-testid="bpm-timesig-display"]`, `[data-testid="transport-button"]`, `[data-testid="transport-controls"]` |
| timeline.spec.ts | Migrated to `[data-testid="timeline-canvas"]`, `[data-testid="time-selection"]`, `[data-testid="region-edit-action-bar"]` |
| studio-layout.spec.ts | Migrated to `[data-testid="settings-tab-bar"]`, `[data-testid="settings-transport-bar"]`, `[data-testid="settings-transport-position"]`, `[data-testid="settings-rec-quick-actions"]`, `[data-testid="modal-backdrop"]` |

**Components updated:**
| Component | Attributes Added |
|-----------|-----------------|
| RegionEditActionBar.tsx | `data-testid="region-edit-action-bar"` |
| SettingsMenu.tsx | `data-testid="settings-tab-bar"`, `data-testid="settings-transport-bar"`, `data-testid="settings-transport-position"`, `data-testid="settings-rec-quick-actions"` |

**All 503 tests pass. Bundle: 692 kB (target ≤1,050 kB).**

**E2E Tests:** `npm run test:e2e` - 102 tests passing

**PR 2 Status:** ✅ COMPLETE
- Unit tests: 503 passing (`npm run test`)
- E2E tests: 102 passing (`npm run test:e2e`)
- All data-testid migrations complete

---

### 2026-01-10 (continued) - PR 3 Complete

**3a. Extracted inline components:**

| New File | From |
|----------|------|
| `Track/MasterTrackStrip.tsx` | MixerSection.tsx inline |
| `Track/TrackStripWithMeter.tsx` | VirtualizedTrackList.tsx inline |
| `Actions/MixerLockButton.tsx` | MixerSection.tsx inline |
| `Actions/UnselectAllTracksButton.tsx` | MixerSection.tsx inline |

**3b. Added aria-pressed to toggle buttons:**

| File | Change |
|------|--------|
| ToggleButton.tsx | `aria-pressed={isActive}` |
| MuteButton.tsx | `aria-pressed={isMuted}` |
| SoloButton.tsx | `aria-pressed={isSoloed}` |
| RecordArmButton.tsx | `aria-pressed={isRecordArmed}` |
| MonitorButton.tsx | `aria-pressed={recordMonitorState !== 'off'}` |
| MasterMonoButton.tsx | `aria-pressed={isMono}` |

**New tests:** 27 tests for extracted components (MasterTrackStrip, TrackStripWithMeter, MixerLockButton, UnselectAllTracksButton)

**PR 3 Status:** ✅ COMPLETE
- Unit tests: 606 passing (`npm run test`)
- Build: 692 kB (target ≤1,050 kB)
- All inline components extracted
- All toggle buttons have aria-pressed
