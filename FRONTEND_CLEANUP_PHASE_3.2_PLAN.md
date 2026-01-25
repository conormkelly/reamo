# Phase 3.2 - CircularTransportButton Extraction

## Goal
Extract and unify the duplicated TransportButton/MiniTransportButton into a single shared component.

## Prerequisites
- Phase 3.1 complete (dead code removed, control height tokens in place)

## Analysis: Current Duplication

### TransportBar.tsx (lines 30-63)
```typescript
interface TransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  inactiveClass?: string;
  title: string;
  children: React.ReactNode;
  pulse?: boolean;
}

function TransportButton({ ... }): ReactElement {
  const colorClasses = {
    green: 'bg-success',
    red: 'bg-error',
    gray: 'bg-bg-disabled',
  };
  // ... w-11 h-11 (44px)
}
```

### PersistentTransport.tsx (lines 36-64)
```typescript
interface MiniTransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  title: string;
  children: React.ReactNode;
  // Missing: inactiveClass, pulse
}

function MiniTransportButton({ ... }): ReactElement {
  const colorClasses = {
    green: 'bg-success',
    red: 'bg-error',
    gray: 'bg-bg-hover',  // Different from TransportButton!
  };
  // ... w-10 h-10 (40px)
}
```

### Differences to Reconcile

| Aspect | TransportButton | MiniTransportButton | Resolution |
|--------|-----------------|---------------------|------------|
| Size | 44px (w-11 h-11) | 40px (w-10 h-10) | Add `size` prop |
| Gray inactive | `bg-bg-disabled` | `bg-bg-hover` | Keep `bg-bg-hover` (more visible) |
| `inactiveClass` prop | Yes | No | Keep (for record button styling) |
| `pulse` prop | Yes | No | Keep (for recording state) |

## Files to Create

### `frontend/src/components/Transport/CircularTransportButton.tsx`

```typescript
/**
 * CircularTransportButton Component
 * Unified circular button for transport controls (play, stop, record, etc.)
 * Used by TransportBar (44px) and PersistentTransport (40px).
 */

import type { ReactElement, ReactNode } from 'react';

export interface CircularTransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  /** Custom inactive styling (e.g., record button ring) */
  inactiveClass?: string;
  title: string;
  children: ReactNode;
  /** Pulsing animation for recording state */
  pulse?: boolean;
  /** Button size: 'sm' = 40px, 'md' = 44px (Apple HIG minimum) */
  size?: 'sm' | 'md';
}

const activeColorClasses = {
  green: 'bg-success',
  red: 'bg-error',
  gray: 'bg-bg-hover',
} as const;

const sizeClasses = {
  sm: 'w-10 h-10',  // 40px - compact (PersistentTransport)
  md: 'w-11 h-11',  // 44px - Apple HIG minimum (TransportBar)
} as const;

export function CircularTransportButton({
  onClick,
  isActive = false,
  activeColor = 'gray',
  inactiveClass,
  title,
  children,
  pulse = false,
  size = 'md',
}: CircularTransportButtonProps): ReactElement {
  const defaultInactiveClass = 'bg-bg-elevated hover:bg-bg-hover';

  return (
    <button
      onClick={onClick}
      title={title}
      aria-label={title}
      aria-pressed={isActive}
      className={`
        ${sizeClasses[size]} rounded-full flex items-center justify-center
        transition-colors
        ${isActive ? activeColorClasses[activeColor] : (inactiveClass || defaultInactiveClass)}
        ${pulse ? 'animate-pulse' : ''}
      `}
    >
      {children}
    </button>
  );
}
```

## Files to Modify

### 1. `frontend/src/components/Transport/TransportBar.tsx`

**Remove:** Lines 20-63 (TransportButtonProps interface and TransportButton function)

**Add import at top:**
```typescript
import { CircularTransportButton } from './CircularTransportButton';
```

**Replace all `TransportButton` usages with `CircularTransportButton`:**
- Line 150-152: Skip to Start button
- Line 155-162: Play button
- Line 165-172: Pause button
- Line 175-182: Loop/Repeat button
- Line 185-192: Stop button

**Note:** Record button (lines 195-214) uses custom pointer handlers for long-press, so it stays as a raw `<button>`. This is intentional - it needs `onPointerDown`/`onPointerUp` for hold-to-toggle-autopunch.

### 2. `frontend/src/components/PersistentTransport.tsx`

**Remove:** Lines 28-64 (MiniTransportButtonProps interface and MiniTransportButton function)

**Add import at top:**
```typescript
import { CircularTransportButton } from './Transport/CircularTransportButton';
```

**Replace all `MiniTransportButton` usages with `CircularTransportButton size="sm"`:**
- Line 175-177: Skip to Start button
- Line 179-186: Play button
- Line 188-195: Pause button
- Line 197-204: Stop button

**Note:** Record button (lines 207-226) uses custom pointer handlers, stays as raw `<button>`.

### 3. `frontend/src/components/Transport/index.ts`

**Add export:**
```typescript
export { CircularTransportButton, type CircularTransportButtonProps } from './CircularTransportButton';
```

## Implementation Steps

1. **Create `CircularTransportButton.tsx`**
   - New file in `frontend/src/components/Transport/`
   - Include size variants ('sm' = 40px, 'md' = 44px)
   - Keep `inactiveClass` and `pulse` props for flexibility

2. **Update barrel export**
   - Add to `frontend/src/components/Transport/index.ts`

3. **Migrate TransportBar.tsx**
   - Add import
   - Remove inline TransportButton definition (lines 20-63)
   - Replace 5 TransportButton usages
   - Keep Record button as raw button (needs pointer handlers)

4. **Migrate PersistentTransport.tsx**
   - Add import
   - Remove inline MiniTransportButton definition (lines 28-64)
   - Replace 4 MiniTransportButton usages with `size="sm"`
   - Keep Record button as raw button

5. **Verify build**
   ```bash
   cd frontend && npm run build
   ```

6. **Visual verification**
   - TransportBar buttons should remain 44px
   - PersistentTransport buttons should remain 40px
   - All buttons should have correct active/inactive styling
   - Record long-press should still toggle auto-punch mode

## Types Added

```typescript
export interface CircularTransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  inactiveClass?: string;
  title: string;
  children: ReactNode;
  pulse?: boolean;
  size?: 'sm' | 'md';
}
```

## Testing Checklist

- [ ] `npm run build` completes without errors
- [ ] TransportBar renders correctly at 44px
- [ ] PersistentTransport renders correctly at 40px
- [ ] Play/Pause/Stop buttons toggle correctly
- [ ] Loop button toggles correctly
- [ ] Skip to Start works
- [ ] Record button still toggles recording (tap)
- [ ] Record button still toggles auto-punch mode (long-press)
- [ ] Recording pulse animation works
- [ ] Button colors match previous (green=success, red=error, gray=hover)

## Risk Assessment

| Factor | Rating | Notes |
|--------|--------|-------|
| Risk Level | **Low** | Straightforward extraction, no logic changes |
| Files Changed | 3 modified + 1 created | |
| Breaking Potential | Low | Visual parity maintained |
| LOC Deduplicated | ~50 | Two inline components → one shared |

## Decision: React Aria

**Recommendation: Skip React Aria for this phase.**

The research suggested React Aria's `useButton` for specialized behavior, but CircularTransportButton is simple enough that native `<button>` with `aria-pressed` and `aria-label` is sufficient. React Aria would add:
- A new dependency (~30KB gzipped for react-aria)
- Extra complexity for minimal accessibility gain
- Potential breaking changes in future updates

The existing pattern already handles:
- `aria-pressed` for toggle state
- `aria-label` for screen readers
- Focus visible states via Tailwind

**Consider React Aria later** if we need:
- Press event normalization across touch/mouse/keyboard
- Complex focus management
- Disabled state handling beyond CSS

## Outcome Documentation

After execution, document in `FRONTEND_CLEANUP_PHASE_3.2_OUTCOME.md`:
- Actual LOC before/after
- Any edge cases discovered
- Visual screenshots confirming parity
- Suggested commit message:
  ```
  refactor(frontend): extract CircularTransportButton from inline definitions

  Unify TransportButton (44px) and MiniTransportButton (40px) into a
  single shared component with size prop. Both inline definitions were
  nearly identical except for dimensions.

  - New: CircularTransportButton.tsx with 'sm' (40px) and 'md' (44px) sizes
  - TransportBar.tsx: uses size="md" (default)
  - PersistentTransport.tsx: uses size="sm"
  - Record buttons remain raw <button> for custom pointer handlers
  - ~50 LOC deduplicated
  ```
