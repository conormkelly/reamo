# Phase 3.1 - Foundation & Dead Code Removal

## Goal
Establish token foundation for button system and remove unused code to reduce cognitive load.

## Prerequisites
- Phase 2 complete (semantic spacing tokens in place)

## Files to Delete

| File | LOC | Why Safe |
|------|-----|----------|
| `frontend/src/components/Actions/ActionButton.tsx` | 94 | Zero imports outside test file (verified via grep) |
| `frontend/src/components/Actions/ToggleButton.tsx` | 97 | Zero imports outside test file |
| `frontend/src/components/Actions/ActionButton.test.tsx` | 225 | Tests for deleted components |
| `frontend/src/components/Transport/PlayButton.tsx` | 35 | Zero imports - TransportBar defines its own |
| `frontend/src/components/Transport/StopButton.tsx` | 35 | Zero imports - TransportBar defines its own |
| `frontend/src/components/Transport/RecordButton.tsx` | 35 | Zero imports - TransportBar defines its own |

**Total LOC Removed:** ~521

## Files to Modify

### 1. `frontend/src/components/Actions/index.ts`
**Current (lines 1-11):**
```typescript
// Base action button
export { ActionButton, type ActionButtonProps } from './ActionButton';

// Mixer / track selection
export { MixerLockButton } from './MixerLockButton';
export { UnselectAllTracksButton } from './UnselectAllTracksButton';

// Other action buttons
export { ToggleButton, type ToggleButtonProps } from './ToggleButton';
export { TimeSignatureButton, type TimeSignatureButtonProps } from './TimeSignatureButton';
```

**After:**
```typescript
// Mixer / track selection
export { MixerLockButton } from './MixerLockButton';
export { UnselectAllTracksButton } from './UnselectAllTracksButton';

// Other action buttons
export { TimeSignatureButton, type TimeSignatureButtonProps } from './TimeSignatureButton';
```

### 2. `frontend/src/components/Transport/index.ts`
**Current (lines 1-7):**
```typescript
export { PlayButton, type PlayButtonProps } from './PlayButton';
export { StopButton, type StopButtonProps } from './StopButton';
export { RecordButton, type RecordButtonProps } from './RecordButton';
export { TimeDisplay, type TimeDisplayProps } from './TimeDisplay';
export { TransportBar, type TransportBarProps } from './TransportBar';
export { RecordingActionsBar, type RecordingActionsBarProps } from './RecordingActionsBar';
```

**After:**
```typescript
export { TimeDisplay, type TimeDisplayProps } from './TimeDisplay';
export { TransportBar, type TransportBarProps } from './TransportBar';
export { RecordingActionsBar, type RecordingActionsBarProps } from './RecordingActionsBar';
```

### 3. `frontend/src/index.css` - Add Control Height Tokens

Add after the existing spacing tokens section (around line 291):

```css
  /* =============================================================================
   * CONTROL HEIGHT TOKENS
   * Shared sizing for interactive controls (buttons, inputs, selects).
   * Three-tier pattern: use these semantic tokens, NOT per-component tokens.
   * Reference: Shopify Polaris, GitHub Primer control sizing systems.
   * ============================================================================= */

  /* --- Control Heights --- */
  --size-control-sm: 2rem;         /* 32px - compact controls */
  --size-control-md: 2.5rem;       /* 40px - default controls */
  --size-control-lg: 2.75rem;      /* 44px - touch-friendly (Apple HIG minimum) */
  --size-control-xl: 3rem;         /* 48px - large touch targets */

  /* --- Touch Target Reference (Apple HIG) --- */
  --size-touch-target-min: 2.75rem;  /* 44px - minimum for accessibility */

  /* =============================================================================
   * INTENT VARIANT TOKENS (Button Colors)
   * Shared color semantics for action buttons across the app.
   * Components reference these instead of defining their own variants.
   * ============================================================================= */

  /* Intent backgrounds */
  --color-intent-primary-bg: var(--color-primary);
  --color-intent-primary-hover: var(--color-primary-hover);
  --color-intent-danger-bg: var(--color-error-action);
  --color-intent-danger-hover: var(--color-error);
  --color-intent-success-bg: var(--color-success-action);
  --color-intent-success-hover: var(--color-success);
  --color-intent-secondary-bg: var(--color-bg-elevated);
  --color-intent-secondary-hover: var(--color-bg-hover);
```

## Implementation Steps

1. **Verify dead code is truly unused**
   ```bash
   # Run from frontend/src directory
   grep -r "ActionButton" --include="*.tsx" | grep -v "ActionButton.tsx" | grep -v "ActionButton.test.tsx"
   grep -r "ToggleButton" --include="*.tsx" | grep -v "ToggleButton.tsx" | grep -v "ActionButton.test.tsx"
   grep -r "import.*PlayButton" --include="*.tsx" | grep -v "PlayButton.tsx" | grep -v "index.ts"
   grep -r "import.*StopButton" --include="*.tsx" | grep -v "StopButton.tsx" | grep -v "index.ts"
   grep -r "import.*RecordButton" --include="*.tsx" | grep -v "RecordButton.tsx" | grep -v "index.ts"
   ```

2. **Delete dead files** (6 files)
   - `rm frontend/src/components/Actions/ActionButton.tsx`
   - `rm frontend/src/components/Actions/ToggleButton.tsx`
   - `rm frontend/src/components/Actions/ActionButton.test.tsx`
   - `rm frontend/src/components/Transport/PlayButton.tsx`
   - `rm frontend/src/components/Transport/StopButton.tsx`
   - `rm frontend/src/components/Transport/RecordButton.tsx`

3. **Update barrel exports**
   - Edit `frontend/src/components/Actions/index.ts` - remove ActionButton, ToggleButton exports
   - Edit `frontend/src/components/Transport/index.ts` - remove PlayButton, StopButton, RecordButton exports

4. **Add control height tokens**
   - Edit `frontend/src/index.css` - add tokens after spacing section

5. **Verify build**
   ```bash
   cd frontend && npm run build
   ```

6. **Verify tests pass**
   ```bash
   cd frontend && npm test
   ```

## Tokens/Types Added

| Token | Value | Purpose |
|-------|-------|---------|
| `--size-control-sm` | 32px | Compact controls (mixer density mode, future) |
| `--size-control-md` | 40px | Default control size |
| `--size-control-lg` | 44px | Touch-friendly (Apple HIG minimum) |
| `--size-control-xl` | 48px | Large touch targets |
| `--size-touch-target-min` | 44px | Reference token for accessibility |
| `--color-intent-primary-*` | - | Primary action colors |
| `--color-intent-danger-*` | - | Destructive action colors |
| `--color-intent-success-*` | - | Positive action colors |
| `--color-intent-secondary-*` | - | Secondary/neutral action colors |

## Testing Checklist

- [ ] `npm run build` completes without errors
- [ ] `npm test` passes (should have fewer tests after ActionButton.test.tsx removal)
- [ ] App loads and renders correctly
- [ ] Transport controls still work (they use inline definitions, not deleted files)
- [ ] Actions view still works (MixerLockButton, UnselectAllTracksButton, TimeSignatureButton)

## Risk Assessment

| Factor | Rating | Notes |
|--------|--------|-------|
| Risk Level | **Low** | Deleting verified unused code |
| Files Changed | 3 modified + 6 deleted | |
| Breaking Potential | None | Dead code has no consumers |

## Outcome Documentation

After execution, document in `FRONTEND_CLEANUP_PHASE_3.1_OUTCOME.md`:
- Actual LOC removed (verify against estimate)
- Any unexpected imports discovered
- Build/test results
- Suggested commit message:
  ```
  refactor(frontend): remove dead button primitives, add control tokens

  Delete ActionButton, ToggleButton (unused despite having tests) and
  standalone transport buttons (superseded by inline TransportButton).

  Add control height tokens (--size-control-sm/md/lg/xl) following
  three-tier pattern from Shopify Polaris. These shared tokens will be
  used by CircularTransportButton and TrackControlButton in Phase 3.2-3.3.

  - 6 files deleted (~521 LOC)
  - Control height + intent variant tokens added to index.css
  - Barrel exports updated
  ```
