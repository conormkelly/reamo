# Phase 3.2 Outcome - CircularTransportButton Extraction

**Date:** 2025-01-25
**Status:** Complete

## What Was Done

### New Component Created

**`frontend/src/components/Transport/CircularTransportButton.tsx`** (~60 LOC)
- Unified circular button for transport controls
- Size variants: `'sm'` (40px) and `'md'` (44px, default)
- Props: `onClick`, `isActive`, `activeColor`, `inactiveClass`, `title`, `children`, `pulse`, `size`
- Active colors: green (bg-success), red (bg-error), gray (bg-bg-hover)

### Files Modified

| File | Changes |
|------|---------|
| `Transport/index.ts` | Added CircularTransportButton export |
| `TransportBar.tsx` | Removed inline TransportButton (34 LOC), now uses CircularTransportButton |
| `PersistentTransport.tsx` | Removed inline MiniTransportButton (29 LOC), now uses CircularTransportButton size="sm" |

### LOC Impact

- **Created:** ~60 LOC (CircularTransportButton.tsx)
- **Removed:** ~63 LOC (inline definitions)
- **Net:** ~3 LOC reduction + deduplication benefit

### Visual Changes

**Minor normalization:** TransportBar's gray active state changed from `bg-bg-disabled` to `bg-bg-hover` to match PersistentTransport. This is a subtle improvement (more visible active state).

## Verification Results

- **Build:** Passed (890.95 kB bundle)
- Bundle size increased by 0.15 kB (expected - new component file)

## Deviations from Plan

1. **Replace_all gotcha:** When replacing `TransportButton` → `CircularTransportButton`, it also changed the import path. Fixed by correcting the import manually.

## Notes

- Record buttons in both TransportBar and PersistentTransport remain raw `<button>` elements. They need custom pointer handlers for long-press auto-punch toggle, which CircularTransportButton doesn't support (intentionally - it uses simple onClick).

## Suggested Commit Message

```
refactor(frontend): extract CircularTransportButton from inline definitions

Unify TransportButton (44px) and MiniTransportButton (40px) into a
single shared component with size prop. Both inline definitions were
nearly identical except for dimensions.

- New: CircularTransportButton.tsx with 'sm' (40px) and 'md' (44px) sizes
- TransportBar.tsx: uses size="md" (default)
- PersistentTransport.tsx: uses size="sm"
- Record buttons remain raw <button> for custom pointer handlers
- Minor visual normalization: gray active state now uses bg-bg-hover consistently

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
```
