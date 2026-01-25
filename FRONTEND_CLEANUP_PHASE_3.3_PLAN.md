# Phase 3.3 - TrackControlButton Extraction

## Goal
Extract shared styling logic from 5 track control buttons into a reusable component, improving accessibility for tri-state toggles.

## Prerequisites
- Phase 3.1 complete (control height tokens available)
- Phase 3.2 complete (establishes component extraction pattern)

## Analysis: Track Button Comparison

| Button | LOC | Padding | Active Color | Interaction | Content |
|--------|-----|---------|--------------|-------------|---------|
| MuteButton | 48 | px-3 py-1 | `bg-primary-hover` | onClick | "M" |
| SoloButton | 67 | px-3 py-1 | `bg-solo` (yellow) | useLongPress | "S" |
| RecordArmButton | 75 | px-2 py-1 | `bg-error-action` | useLongPress + sheet | Circle icon |
| MonitorButton | 62 | px-2 py-1 | 3 states | onClick (cycles) | Headphones icon |
| MasterMonoButton | 53 | px-2 py-1 | `bg-warning-bright` | onClick | Icon toggle |

### Shared Code (Duplicated in Each File)

**Inactive background logic (lines 32-34 / 48-50 / 31-34 / 34-36):**
```typescript
const inactiveBg = isSelected
  ? 'bg-bg-surface text-text-tertiary hover:bg-bg-elevated'
  : 'bg-bg-deep text-text-tertiary hover:bg-bg-surface';
```

**Common class pattern:**
```typescript
className={`px-X py-1 rounded text-sm font-medium transition-colors ${
  mixerLocked ? 'opacity-50 cursor-not-allowed' : ''
} ${isActive ? activeClass : inactiveBg} ${className}`}
```

### Key Differences (Must Preserve)

1. **Padding:** `px-3` (Mute/Solo) vs `px-2` (others) - text labels need more width
2. **Active colors:** Domain-specific (mute=blue, solo=yellow, arm=red, monitor=gray/red, mono=orange)
3. **Interaction patterns:** Simple onClick vs useLongPress vs cycling
4. **MasterMonoButton:** No `mixerLocked` check (master track doesn't lock)
5. **MonitorButton:** Tri-state toggle requires special accessibility handling

## Accessibility Analysis

### Binary Toggles (Mute, Solo, Arm, Mono)
Current pattern is **correct**:
```tsx
<button aria-pressed={isActive} ... />
```

### Tri-State Toggle (Monitor: off → on → auto)
Current pattern is **problematic**:
```tsx
<button aria-pressed={recordMonitorState !== 'off'} ... />
```

This treats "on" and "auto" as the same pressed state, losing information for screen readers.

**Research recommendation:** Use cycling button with live region announcement:
```tsx
<button aria-label={`Monitor mode: ${state}`}>
  ...
</button>
<span role="status" aria-live="polite" className="sr-only">
  Monitor mode changed to {state}
</span>
```

## Design Decision: Component Architecture

**Option A: Thin wrapper component (RECOMMENDED)**
- Extract only the shared inactive styling into a utility
- Each button file keeps its domain logic
- Preserves explicit type definitions per button
- Lower risk, incremental improvement

**Option B: Full TrackControlButton primitive**
- Generic component with many props
- Risk of prop explosion and awkward API
- May not fit all edge cases (MonitorButton 3-state, MasterMonoButton no lock)

**Decision: Option A** - Create a utility for shared styling, not a full component.

## Files to Create

### 1. `frontend/src/components/Track/trackControlStyles.ts`

```typescript
/**
 * Shared styling utilities for track control buttons.
 * Extracted to reduce duplication while preserving explicit button implementations.
 */

/**
 * Returns inactive background classes based on selection state.
 * All track control buttons use this pattern for consistent visual hierarchy.
 */
export function getInactiveClasses(isSelected: boolean): string {
  return isSelected
    ? 'bg-bg-surface text-text-tertiary hover:bg-bg-elevated'
    : 'bg-bg-deep text-text-tertiary hover:bg-bg-surface';
}

/**
 * Returns the mixer locked classes if applicable.
 */
export function getLockedClasses(mixerLocked: boolean): string {
  return mixerLocked ? 'opacity-50 cursor-not-allowed' : '';
}

/**
 * Base class string for all track control buttons.
 * Individual buttons compose this with their specific padding and active classes.
 */
export const trackControlBaseClasses = 'rounded text-sm font-medium transition-colors';
```

## Files to Modify

### 1. `frontend/src/components/Track/MuteButton.tsx`

**Replace lines 31-34:**
```typescript
// Before
const inactiveBg = isSelected
  ? 'bg-bg-surface text-text-tertiary hover:bg-bg-elevated'
  : 'bg-bg-deep text-text-tertiary hover:bg-bg-surface';

// After
import { getInactiveClasses, getLockedClasses, trackControlBaseClasses } from './trackControlStyles';
// ...
const inactiveBg = getInactiveClasses(isSelected);
const lockedClasses = getLockedClasses(mixerLocked);
```

**Update button className (line 41-43):**
```typescript
className={`px-3 py-1 ${trackControlBaseClasses} ${lockedClasses} ${
  isMuted ? 'bg-primary-hover text-text-on-primary' : inactiveBg
} ${className}`}
```

### 2. `frontend/src/components/Track/SoloButton.tsx`

**Same pattern:** Import utilities, replace inline calculations.

### 3. `frontend/src/components/Track/RecordArmButton.tsx`

**Same pattern:** Import utilities, replace inline calculations.

### 4. `frontend/src/components/Track/MonitorButton.tsx`

**Additional accessibility fix:**

```typescript
// Add live region for state announcements
const [announced, setAnnounced] = useState('');

const handleClick = () => {
  if (mixerLocked) return;
  sendCommand(cycleRecordMonitor());
  // Announce after state change (next cycle state)
  const nextState = recordMonitorState === 'off' ? 'on'
    : recordMonitorState === 'on' ? 'auto' : 'off';
  setAnnounced(`Monitor mode: ${nextState}`);
};

// In return:
<>
  <button
    onClick={handleClick}
    aria-label={`Monitor mode: ${stateLabels[recordMonitorState]}`}
    // Remove aria-pressed for tri-state
    ...
  />
  <span role="status" aria-live="polite" className="sr-only">
    {announced}
  </span>
</>
```

### 5. `frontend/src/components/Track/MasterMonoButton.tsx`

**Note:** MasterMonoButton doesn't use `mixerLocked`, so only use `getInactiveClasses`.

### 6. `frontend/src/components/Track/index.ts`

No changes needed - we're not exporting the utility (it's internal).

## Implementation Steps

1. **Create `trackControlStyles.ts`**
   - New file with shared utility functions
   - No component, just pure functions

2. **Migrate MuteButton.tsx**
   - Add import
   - Replace inline inactive calculation
   - Use utility functions
   - Verify visually identical

3. **Migrate SoloButton.tsx**
   - Same pattern
   - Preserve useLongPress logic

4. **Migrate RecordArmButton.tsx**
   - Same pattern
   - Preserve useLongPress and InputSelectionSheet logic

5. **Migrate MonitorButton.tsx**
   - Same pattern for styling
   - **Add accessibility fix:** live region for state announcements
   - Remove `aria-pressed` (not appropriate for tri-state)
   - Add `aria-label` with full state name

6. **Migrate MasterMonoButton.tsx**
   - Same pattern (no mixerLocked)
   - Keep `aria-pressed` (binary toggle)

7. **Verify build and functionality**
   ```bash
   cd frontend && npm run build && npm test
   ```

## Testing Checklist

- [ ] `npm run build` completes without errors
- [ ] `npm test` passes
- [ ] MuteButton toggles correctly, visual identical
- [ ] SoloButton tap/long-press both work
- [ ] RecordArmButton tap/long-press both work
- [ ] MonitorButton cycles through all 3 states
- [ ] MonitorButton announces state changes to screen readers
- [ ] MasterMonoButton toggles correctly
- [ ] All buttons respect `isSelected` styling
- [ ] Mute/Solo/RecordArm respect `mixerLocked` state
- [ ] MasterMonoButton ignores `mixerLocked` (correct behavior)

## Accessibility Improvements

| Button | Before | After |
|--------|--------|-------|
| MuteButton | `aria-pressed` | `aria-pressed` (no change) |
| SoloButton | `aria-pressed` | `aria-pressed` (no change) |
| RecordArmButton | `aria-pressed` | `aria-pressed` (no change) |
| MonitorButton | `aria-pressed` (wrong for 3-state) | `aria-label` + live region |
| MasterMonoButton | `aria-pressed` | `aria-pressed` (no change) |

## Risk Assessment

| Factor | Rating | Notes |
|--------|--------|-------|
| Risk Level | **Medium** | MonitorButton accessibility change needs careful testing |
| Files Changed | 6 (5 modified + 1 created) | |
| Breaking Potential | Low | Visual parity maintained |
| LOC Deduplicated | ~25 | Shared inactive styling logic |

## Open Questions for User

1. **Non-color indicators:** Research recommends adding icons or text labels alongside color for accessibility. Should we:
   - Add always-visible text labels ("M", "S", "R") - currently only Mute/Solo have them
   - Add small indicator icons in addition to existing content
   - Defer to visual polish phase

2. **Touch targets:** Track buttons are ~24-36px, below 44px minimum. Should we:
   - Increase button size now (may affect mixer density)
   - Add density mode toggle (compact vs accessible)
   - Defer to separate phase

## Outcome Documentation

After execution, document in `FRONTEND_CLEANUP_PHASE_3.3_OUTCOME.md`:
- LOC before/after each file
- Accessibility testing results (VoiceOver/TalkBack)
- Any edge cases discovered
- Suggested commit message:
  ```
  refactor(frontend): extract track button styling, fix Monitor accessibility

  Extract shared inactive styling logic into trackControlStyles.ts utility.
  All 5 track buttons now use getInactiveClasses() instead of duplicating
  the isSelected logic.

  Accessibility fix for MonitorButton: Replace aria-pressed (wrong for
  tri-state) with aria-label and live region announcement. Screen readers
  now correctly announce "Monitor mode: On/Off/Auto" on state change.

  - New: trackControlStyles.ts with getInactiveClasses(), getLockedClasses()
  - Updated: MuteButton, SoloButton, RecordArmButton, MonitorButton, MasterMonoButton
  - ~25 LOC deduplicated
  - MonitorButton accessibility improved (WCAG 4.1.2)
  ```
