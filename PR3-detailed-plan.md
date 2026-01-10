# PR3: Component Architecture Cleanup - Detailed Plan

**Goal**: Clean architecture before MixerView and Viewport-Aware Timeline features.

**Strategy**: Incremental, non-breaking changes with comprehensive tests.

---

## Overview

| Task | Files | Risk | Effort |
|------|-------|------|--------|
| 3a. Extract Inline Components | 8 new files, 4 modified | Low | Small |
| 3b. Button A11y Fixes | 6 modified | Low | Small |
| 3c. Store Selector Consistency | Already clean | N/A | None |

**Total new files**: 8 (4 components + 4 tests)
**Total modified files**: 10

---

## 3a. Extract Inline Components

### Components to Extract

#### 1. MasterTrackStrip
**From**: `frontend/src/components/Studio/MixerSection.tsx:16-24`
**To**: `frontend/src/components/Track/MasterTrackStrip.tsx`

```tsx
// Simple extraction - zero coupling
export function MasterTrackStrip() {
  return (
    <div className="flex gap-1 flex-shrink-0">
      <LevelMeter trackIndex={0} height={200} />
      <TrackStrip trackIndex={0} />
    </div>
  );
}
```

**Test**: Verify master track (index 0) renders with LevelMeter and TrackStrip.

#### 2. TrackStripWithMeter
**From**: `frontend/src/components/Studio/VirtualizedTrackList.tsx:32-39`
**To**: `frontend/src/components/Track/TrackStripWithMeter.tsx`

```tsx
interface TrackStripWithMeterProps {
  trackIndex: number;
}

export function TrackStripWithMeter({ trackIndex }: TrackStripWithMeterProps) {
  return (
    <div className="flex gap-1 flex-shrink-0">
      <LevelMeter trackIndex={trackIndex} height={200} />
      <TrackStrip trackIndex={trackIndex} />
    </div>
  );
}
```

**Test**: Verify trackIndex prop is passed correctly to children.

#### 3. MixerLockButton
**From**: `frontend/src/components/Studio/MixerSection.tsx:26-43`
**To**: `frontend/src/components/Actions/MixerLockButton.tsx`

```tsx
export function MixerLockButton() {
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const toggleMixerLock = useReaperStore((s) => s.toggleMixerLock);

  return (
    <button
      onClick={toggleMixerLock}
      aria-pressed={mixerLocked}
      title={mixerLocked ? 'Unlock mixer controls' : 'Lock mixer controls'}
      className={`p-2 rounded transition-colors ${
        mixerLocked
          ? 'bg-warning text-text-primary'
          : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
      }`}
    >
      {mixerLocked ? <Lock size={18} /> : <Unlock size={18} />}
    </button>
  );
}
```

**Note**: Added `aria-pressed` during extraction.

**Test**: Verify toggle state, icon changes, store interaction.

#### 4. UnselectAllTracksButton
**From**: `frontend/src/components/Studio/MixerSection.tsx:45-61`
**To**: `frontend/src/components/Actions/UnselectAllTracksButton.tsx`

```tsx
export function UnselectAllTracksButton() {
  const { sendCommand } = useReaper();
  const { selectedTracks } = useTracks();

  if (selectedTracks.length === 0) return null;

  return (
    <button
      onClick={() => sendCommand(trackCmd.unselectAll())}
      title="Deselect all tracks"
      className="p-2 rounded transition-colors bg-bg-elevated text-text-tertiary hover:bg-bg-hover"
    >
      <XCircle size={18} />
    </button>
  );
}
```

**Test**: Verify visibility conditional, command sends.

### Files to Modify

| File | Changes |
|------|---------|
| `frontend/src/components/Track/index.ts` | Add exports for MasterTrackStrip, TrackStripWithMeter |
| `frontend/src/components/Actions/index.ts` | Add exports for MixerLockButton, UnselectAllTracksButton |
| `frontend/src/components/Studio/MixerSection.tsx` | Remove inline definitions, add imports |
| `frontend/src/components/Studio/VirtualizedTrackList.tsx` | Remove inline definition, add import |

---

## 3b. Button A11y Fixes

Keep ActionButton and ToggleButton separate (different semantics: fire-and-forget vs show-state).

### A11y Fixes for Toggle Buttons

Add `aria-pressed` to all track buttons:

| File | Add |
|------|-----|
| `ToggleButton.tsx` | `aria-pressed={isActive}` |
| `MuteButton.tsx` | `aria-pressed={isMuted}` |
| `SoloButton.tsx` | `aria-pressed={isSolo}` |
| `RecordArmButton.tsx` | `aria-pressed={isArmed}` |
| `MonitorButton.tsx` | `aria-pressed={monitor !== 'off'}` |
| `MasterMonoButton.tsx` | `aria-pressed={isMono}` |

**Example change** (MuteButton.tsx:36):

```tsx
<button
  onClick={handleClick}
  aria-pressed={isMuted}  // ADD THIS
  title={isMuted ? 'Unmute Track' : 'Mute Track'}
  // ...
```

### Phase 4: Icon Size Consistency (Optional)

Document standard icon sizes but don't refactor existing code:

| Context | Size | Example |
|---------|------|---------|
| Small buttons (track controls) | 14-16px | Mute, Solo |
| Medium buttons (toolbar) | 18px | MixerLockButton |
| Large buttons (transport) | 20-24px | Play, Record |

---

## 3c. Store Selector Consistency

**Status: Already Clean** - No action required.

Verified:
- ✅ 6 `EMPTY_*` constants exist and are used correctly
- ✅ No inline `?? {}` or `?? []` fallbacks
- ✅ All defensive selectors use stable refs
- ✅ Atomic selectors used consistently (no useShallow needed)

---

## Implementation Order

1. **Extract inline components** (3a)
   - Create 4 new component files
   - Update barrel exports
   - Modify source files to import
   - Verify no regressions

2. **Add tests for extracted components**
   - MasterTrackStrip.test.tsx
   - TrackStripWithMeter.test.tsx
   - MixerLockButton.test.tsx
   - UnselectAllTracksButton.test.tsx

3. **A11y fixes for toggle buttons** (3b)
   - Add aria-pressed to 5 track button files + ToggleButton
   - No visual/behavioral changes

4. **Run full test suite**
   - Verify all 500+ tests pass
   - Run E2E tests

---

## Test Plan

### Unit Tests to Add

| Test File | Coverage |
|-----------|----------|
| `MasterTrackStrip.test.tsx` | Renders LevelMeter + TrackStrip for index 0 |
| `TrackStripWithMeter.test.tsx` | Passes trackIndex prop correctly |
| `MixerLockButton.test.tsx` | Toggle state, icon switch, aria-pressed |
| `UnselectAllTracksButton.test.tsx` | Visibility when no selection, command send |

### E2E Verification

Existing E2E tests should pass without modification:
- `mixer-section.spec.ts` (if exists)
- `track-selection.spec.ts`

---

## Files Summary

### New Files (10)

```
frontend/src/components/Track/MasterTrackStrip.tsx
frontend/src/components/Track/MasterTrackStrip.test.tsx
frontend/src/components/Track/TrackStripWithMeter.tsx
frontend/src/components/Track/TrackStripWithMeter.test.tsx
frontend/src/components/Actions/MixerLockButton.tsx
frontend/src/components/Actions/MixerLockButton.test.tsx
frontend/src/components/Actions/UnselectAllTracksButton.tsx
frontend/src/components/Actions/UnselectAllTracksButton.test.tsx
```

### Modified Files (10)

```
frontend/src/components/Track/index.ts
frontend/src/components/Actions/index.ts
frontend/src/components/Studio/MixerSection.tsx
frontend/src/components/Studio/VirtualizedTrackList.tsx
frontend/src/components/Actions/ToggleButton.tsx (add aria-pressed)
frontend/src/components/Track/MuteButton.tsx
frontend/src/components/Track/SoloButton.tsx
frontend/src/components/Track/RecordArmButton.tsx
frontend/src/components/Track/MonitorButton.tsx
frontend/src/components/Track/MasterMonoButton.tsx
```

---

## Success Criteria

- [ ] All 4 inline components extracted to dedicated files
- [ ] All extracted components have unit tests
- [ ] All 6 toggle buttons have aria-pressed (5 track buttons + ToggleButton)
- [ ] All existing tests pass (500+)
- [ ] E2E tests pass
- [ ] No visual/behavioral regressions

---

## Test Conventions

Follow existing patterns from `Modal.test.tsx`:

```typescript
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';

describe('ComponentName', () => {
  const defaultProps = { /* ... */ };

  beforeEach(() => vi.clearAllMocks());
  afterEach(() => cleanup());

  describe('feature area', () => {
    it('does specific behavior', () => { /* ... */ });
  });
});
```
