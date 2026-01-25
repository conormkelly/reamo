# Phase 3.3 Outcome - TrackControlButton Styling Extraction

**Date:** 2025-01-25
**Status:** Complete

## What Was Done

### New File Created

**`frontend/src/components/Track/trackControlStyles.ts`** (~30 LOC)

Shared styling utilities for track control buttons:
- `getInactiveClasses(isSelected: boolean): string` - Returns inactive background classes
- `getLockedClasses(mixerLocked: boolean): string` - Returns mixer locked classes
- `trackControlBaseClasses` - Base class string for all track control buttons

### Files Modified (5 buttons)

| File | LOC Before | LOC After | Changes |
|------|------------|-----------|---------|
| MuteButton.tsx | 48 | 48 | Import utilities, use shared functions |
| SoloButton.tsx | 67 | 67 | Import utilities, use shared functions |
| RecordArmButton.tsx | 75 | 74 | Import utilities, use shared functions |
| MonitorButton.tsx | 62 | 76 | **Accessibility fix** + shared utilities |
| MasterMonoButton.tsx | 53 | 49 | Import utilities (no getLockedClasses - intentional) |

### MonitorButton Accessibility Fix

**Problem:** Using `aria-pressed={recordMonitorState !== 'off'}` conflates "on" and "auto" states. Screen readers couldn't distinguish between them.

**Solution:**
- Removed `aria-pressed` (wrong for tri-state toggles)
- Added `aria-label={stateLabels[recordMonitorState]}` for current state
- Added live region (`<span role="status" aria-live="polite">`) to announce state changes

**Before:**
```tsx
<button aria-pressed={recordMonitorState !== 'off'}>
```

**After:**
```tsx
<>
  <button aria-label={stateLabels[recordMonitorState]}>
  <span role="status" aria-live="polite" className="sr-only">
    {announcement}
  </span>
</>
```

### LOC Impact

- **Created:** ~30 LOC (trackControlStyles.ts)
- **Net change:** ~+15 LOC (MonitorButton grew due to accessibility fix)
- **Deduplication benefit:** 5 files now share single source of truth for inactive styling

## Verification Results

- **Build:** Passed (890.59 kB bundle)
- **Tests:** 900/904 passed
  - 4 pre-existing failures in Timeline.test.tsx (playhead viewport calculations)
  - Unrelated to button changes

## Deviations from Plan

None - executed as planned.

## Notes

1. **MasterMonoButton doesn't use mixerLocked** - This is intentional (master track doesn't lock). Only imported `getInactiveClasses` and `trackControlBaseClasses`.

2. **SoloButton preserves `touch-none`** - Required for long-press gesture handling. Kept in the className.

3. **RecordArmButton doesn't have `touch-none`** - Inconsistency from before this phase; not changed to avoid scope creep.

4. **stateLabels moved outside component** - MonitorButton's `stateLabels` was moved to module scope (with `as const`) since it's static.

## Suggested Commit Message

```
refactor(frontend): extract track button styling, fix Monitor accessibility

Extract shared inactive styling logic into trackControlStyles.ts utility.
All 5 track buttons now use getInactiveClasses() instead of duplicating
the isSelected-based background logic.

Accessibility fix for MonitorButton: Replace aria-pressed (wrong for
tri-state toggles) with aria-label and live region announcement. Screen
readers now correctly announce "Monitor mode: Off/On/Auto" on state change.

- New: trackControlStyles.ts with getInactiveClasses(), getLockedClasses()
- Updated: MuteButton, SoloButton, RecordArmButton, MonitorButton, MasterMonoButton
- ~25 LOC of duplicated inactive styling logic consolidated
- MonitorButton accessibility improved (WCAG 4.1.2 Name, Role, Value)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
```
