# Timeline Component Test Plan

> **Handoff Document** - This captures work done and provides context for continuing.

## Context

**What this is:** Reamo is a web control surface for REAPER (DAW). The Timeline component (~1400 lines) is the most complex part - it handles region editing with ripple logic, gestures, and real-time sync with REAPER.

**Why we're testing:** The Timeline has grown complex. We need test coverage to confidently refactor and modularize without breaking features.

**Bug fixed this session:** Regions could only be moved once before being "locked" until Save/Cancel. Fixed by removing the `hasPendingChanges()` guard in `handlePointerDown` ([Timeline.tsx:456-458](../Timeline.tsx#L456-L458)).

---

## What's Been Built

### Test Infrastructure (`src/test/`)

```txt
src/test/
├── index.ts        # Central export
├── setup.ts        # Vitest config (cleanup, store reset)
├── fixtures.ts     # Test data factories
├── store.ts        # Store utilities & actions
├── gestures.ts     # Pointer event simulation
└── queries.ts      # DOM element queries
```

### Key Utilities

**Fixtures** - Create test data:

```typescript
import { songStructure, BPM, region, bars } from '../../test/fixtures'

const regions = songStructure()  // Intro[0-10], Verse[10-20], Chorus[20-30]
```

**Store** - Interact with state:

```typescript
import { setupStore, findRegion, positions, actions, hasPendingChanges } from '../../test/store'

setupStore(songStructure())           // Reset store with regions
actions.move([0], 5)                  // Move region 0 forward 5s
actions.resize(0, 'end', 15, BPM)     // Extend region end
expect(findRegion('Intro')?.start).toBe(5)
```

**Gestures** - Simulate pointer events:

```typescript
import { tap, drag, longPress, point } from '../../test/gestures'

tap(element, point(100, 50))
drag(element, point(100, 50), point(200, 50))
await longPress(element, point(100, 50), 500)
```

**Queries** - Find and inspect DOM elements:

```typescript
import { findRegionElement, isVisuallySelected, getCenter } from '../../test/queries'

const el = findRegionElement(container, 'Intro')
expect(isVisuallySelected(el)).toBe(true)
```

### Current Test Coverage

**58 tests passing** in 3 files:

- `regionEditSlice.test.ts` - 9 tests (original, less clean)
- `regionEditSlice.behavior.test.ts` - 29 tests (behavior-driven, uses new utilities)
- `Timeline.test.tsx` - 20 tests (component integration tests)

---

## Test Philosophy

### Do This

- **Behavior-driven**: Tests describe user actions and expected outcomes
- **Use fixtures**: `songStructure()`, not inline region arrays
- **Use actions**: `actions.move([0], 5)`, not `store.moveRegion(...)`
- **Find by name**: `findRegion('Intro')`, not `displayRegions[0]`
- **Test outcomes**: "section moves to position 5", not "pendingChanges[0].newStart === 5"

### Don't Do This

- Don't test internal implementation details
- Don't assert on intermediate state (unless specifically testing state machine)
- Don't write brittle tests that break on refactoring
- Don't duplicate coverage (behavior tests cover what unit tests cover)

### Example: Good Test

```typescript
describe('moving a section', () => {
  it('reorders other sections', () => {
    actions.move([2], -10)  // Move Chorus between Intro and Verse

    expect(regionOrder()).toEqual(['Intro', 'Chorus', 'Verse'])
  })
})
```

### Example: Bad Test

```typescript
it('updates pendingChanges with correct originalIdx', () => {
  // Too implementation-focused, will break on refactoring
})
```

---

## What's Left To Do

### Phase 1: Complete State Logic Tests ✅ (mostly done)

The behavior tests cover most of the state logic. Consider adding:

- [ ] Drag state management (`startDrag`, `updateDrag`, `endDrag`)
- [ ] `getDragPreviewRegions()` - live preview during drag
- [ ] Edge cases: negative region keys, index mapping

### Phase 2: Component Integration Tests ✅ (done)

Component tests now exist in `Timeline.test.tsx` with 20 tests covering:

- State integration (store → component sync)
- Visual state verification (selection, pending changes)
- All core behaviors (selection, move, resize, delete, create)
- Bug fix verification (multiple moves before commit)

**Implementation notes:**

- `useReaper` hook is mocked to provide `send: vi.fn()`
- `getBoundingClientRect` is mocked globally for positioning
- Tests use store actions and verify component reflects state correctly
- Pointer event gesture tests deferred to Playwright (complex DOM mocking needed)

### Phase 3: E2E Tests ✅ (done)

Playwright tests in `e2e/timeline.spec.ts` with 6 tests covering:

- Region display verification
- Tap to select region
- Tap to change selection
- Tap empty area to clear selection
- Drag to move region (shows pending changes)
- Cancel reverts pending changes

**Run E2E tests:** `npm run test:e2e`

**Key implementation details:**

- Store exposed on `window.__REAPER_STORE__` in dev mode
- Must set `localStorage.setItem('reamo-timeline-mode', 'regions')` before switching modes
  (the TimelineModeToggle useEffect restores from localStorage on mount)
- Use `store.getState().setTimelineMode('regions')` action, not raw setState

---

## Test Checklist

### State Slice (regionEditSlice) - 80% covered

#### Mode Management

- [x] Switching to navigate mode cancels pending changes
- [x] Switching modes clears selection

#### Selection

- [x] Select single region
- [x] Add to selection
- [x] Deselect region
- [x] Clear selection
- [ ] Selection indices sorted (implicit)

#### Move Region

- [x] Move forward
- [x] Move backward
- [x] Move to position 0
- [x] Ripple shifts other regions
- [x] Multi-region move
- [ ] Duration preserved (implicit)

#### Resize Region

- [x] Extend end
- [x] Shrink end
- [x] Extend start (trims previous)
- [x] Ripple subsequent regions
- [x] Minimum length enforced

#### Create Region

- [x] Creates at position
- [x] Marks as pending
- [x] Shifts following regions
- [ ] Trims containing region

#### Delete Region

- [x] Ripple back mode
- [x] Leave gap mode
- [x] Extend previous mode
- [ ] Delete new region (removes entirely)

#### Pending Changes

- [x] hasPendingChanges()
- [x] commitChanges()
- [x] cancelChanges()
- [x] getDisplayRegions()
- [ ] New regions (negative keys)

#### Drag State

- [ ] startDrag
- [ ] updateDrag
- [ ] endDrag / cancelDrag
- [ ] getDragPreviewRegions

### Component Tests - 80% covered

#### State Integration (Timeline.test.tsx)

- [x] Displays all regions from store
- [x] Shows selected state visually
- [x] Reflects moved region position
- [x] Reverts to original positions after cancel
- [x] Updates region order after move

#### Behavior via Store Actions (Timeline.test.tsx)

- [x] Selection (single, multi, clear)
- [x] Move (forward, backward, ripple)
- [x] Resize (extend, shrink, start edge)
- [x] Delete (ripple, gap, extend previous)
- [x] Create (position, pending, shift following)

#### Gesture Tests (e2e/timeline.spec.ts) ✅

- [x] Tap region → select (pointer events)
- [x] Tap to change selection
- [x] Tap empty area → clear selection
- [x] Drag → move with pending changes
- [ ] Edge drag → resize
- [ ] Long-press → edit modal
- [ ] Navigate mode gestures

### Visual Tests - 0% covered (future)

- [ ] Region positioning (pixel-perfect)
- [ ] Selection highlighting
- [ ] Insertion indicator
- [ ] Resize indicator

---

## Files Reference

| File | Lines | Purpose |
|------|-------|---------|
| `regionEditSlice.ts` | ~980 | State logic for region editing |
| `Timeline.tsx` | ~1400 | Main component with gesture handling |
| `Timeline.test.tsx` | ~380 | Component integration tests |
| `AddRegionModal.tsx` | ~150 | Modal for creating regions |
| `DeleteRegionModal.tsx` | ~100 | Modal with delete options |
| `RegionEditActionBar.tsx` | ~80 | Save/Cancel/Add buttons |
| `RegionInfoBar.tsx` | ~60 | Shows selected region info |
| `TimelineModeToggle.tsx` | ~40 | Navigate/Regions mode toggle |
| `MarkerEditModal.tsx` | ~200 | Marker editing modal |

---

## Lessons Learned

1. **Zustand state is synchronous** - Always call `useReaperStore.getState()` fresh after mutations, don't cache the result.

2. **Display indices ≠ region indices** - Regions are sorted by start time for display. Use `_pendingKey` to map back to original indices.

3. **The ripple logic is complex** - "Remove then insert" behavior means moving a region forward causes the region behind it to fill the gap.

4. **Tests should use `findRegion(name)`** - Not `displayRegions[0]` because order changes after moves.

5. **Long-press needs async** - Use `vi.useFakeTimers()` and `vi.advanceTimersByTime()` for testing hold gestures.

6. **Pointer events in JSDOM are limited** - Full gesture testing (tap, drag) requires mocking `containerRef.current.getBoundingClientRect()` at the right time. State integration tests (action → visual result) are more reliable. Use Playwright for real gesture testing.

---

## Quick Start for Next Session

```bash
# Run tests
npm run test:run

# Run tests in watch mode
npm test

# Run specific test file
npm test -- regionEditSlice.behavior
```

To add a new behavior test:

```typescript
// src/store/slices/regionEditSlice.behavior.test.ts

describe('New Feature', () => {
  beforeEach(() => setupStore(songStructure()))

  it('does the thing', () => {
    actions.someAction()
    expect(findRegion('Intro')?.property).toBe(expected)
  })
})
```

To add a component test:

```typescript
// src/components/Timeline/Timeline.test.tsx

import { render, cleanup, act } from '@testing-library/react'
import { Timeline } from './Timeline'
import { setupStore, actions, findRegion } from '../../test/store'
import { songStructure } from '../../test/fixtures'
import { findRegionElement, isVisuallySelected } from '../../test/queries'

describe('Timeline', () => {
  beforeEach(() => {
    setupStore(songStructure())
    Element.prototype.getBoundingClientRect = vi.fn(() => mockRect)
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  it('shows selected region visually', () => {
    act(() => { actions.select(0) })

    const { container } = render(<Timeline height={120} />)
    const intro = findRegionElement(container, 'Intro')
    expect(isVisuallySelected(intro!)).toBe(true)
  })
})
```

---

Good luck! The infrastructure is solid - just write tests that describe what users do and what they see.
