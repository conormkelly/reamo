# Toolbar Responsive Redesign - Layout-Aware System

## Problem Statement

The toolbar needs to work in three distinct layout contexts:

1. **Portrait footer** (SecondaryPanel): 96px height → horizontal strip
2. **Landscape side rail** (ContextRail): 200px width → vertical stack
3. **ActionsView**: Full screen → flex-wrap grid

The previous 4×2 grid attempt failed because 2 rows in 96px = ~44px per row (below 48px minimum).

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Side rail layout | Single column | 48px buttons, works at 72px collapsed width too |
| Responsive approach | Explicit layout prop | Works with existing patterns, no container queries |
| Touch targets | 48px minimum | Per UX_GUIDELINES.md and Material Design 3 |

## Architecture

### Layout Modes

```typescript
type ToolbarLayout = 'horizontal' | 'vertical' | 'grid';
```

| Mode | Use Case | Button Arrangement |
|------|----------|-------------------|
| `horizontal` | Portrait footer (96px) | Single row, 4 buttons, swipe paging |
| `vertical` | Side rail (200px wide) | Single column, scrollable |
| `grid` | ActionsView (full screen) | Flex-wrap, configurable sizes |

### Component Hierarchy

```
Toolbar (layout prop)
├── horizontal → 1×4 grid, swipe paging, 48px+ height
├── vertical → Single column, scroll, 48px height each
└── grid → Flex-wrap (ActionsView pattern, unchanged)

ToolbarButton (adapts to parent layout)
├── In horizontal/vertical → fills cell (w-full h-full)
└── In grid → explicit size prop (sm/md/lg)
```

## Files to Modify

| File | Changes |
|------|---------|
| `frontend/src/components/Toolbar/Toolbar.tsx` | Add `layout` prop, implement horizontal/vertical modes |
| `frontend/src/components/Toolbar/ToolbarButton.tsx` | Add `layout` prop for sizing adaptation |
| `frontend/src/views/timeline/TimelineView.tsx` | Pass `layout="horizontal"` to footer, `layout="vertical"` to side rail |

**No changes needed:**

- `toolbarSlice.ts` - state management unchanged
- `ActionsView.tsx` / `ActionsGrid.tsx` - keep flex-wrap pattern
- `ToolbarEditor.tsx` - works as-is

## Implementation Details

### 1. Toolbar.tsx - Layout Modes

```tsx
interface ToolbarProps {
  layout?: ToolbarLayout;  // default: 'horizontal'
}

// Horizontal mode (portrait footer): 1 row × 4 columns, swipe paging
const HORIZONTAL_SLOTS = 4;

// Vertical mode (side rail): single column, scrollable
// Grid mode: used by ActionsView via ActionsGrid (not Toolbar directly)
```

**Horizontal layout (portrait footer):**

```tsx
<div className="grid gap-1 h-full" style={{
  gridTemplateColumns: 'repeat(4, 1fr)',
  gridTemplateRows: '1fr',  // Single row fills height
}}>
  {/* 4 buttons per page, swipe for more */}
</div>
```

**Vertical layout (side rail):**

```tsx
<div className="flex flex-col gap-2 overflow-y-auto">
  {toolbarActions.map(action => (
    <ToolbarButton layout="vertical" ... />  // 48px height, full width
  ))}
</div>
```

### 2. ToolbarButton.tsx - Layout Adaptation

```tsx
interface ToolbarButtonProps {
  // ... existing props
  layout?: 'horizontal' | 'vertical' | 'grid';
  size?: ButtonSize;  // Only used when layout='grid'
}

// Sizing by layout:
const LAYOUT_CONFIG = {
  horizontal: {
    container: 'w-full h-full',  // Fill grid cell
    icon: 20,
    text: 'text-xs'
  },
  vertical: {
    container: 'w-full h-12 min-h-[48px]',  // 48px height, full width
    icon: 20,
    text: 'text-xs'
  },
  grid: null,  // Uses SIZE_CONFIG with size prop (existing behavior)
};
```

### 3. TimelineView.tsx Integration

```tsx
// Portrait footer
const toolbarTabContent = useMemo(() => (
  <div className="flex flex-col h-full">
    <ToolbarHeaderControls />
    <Toolbar layout="horizontal" />
  </div>
), []);

// Side rail (when isLandscapeConstrained)
const sideRailToolbarContent = useMemo(() => (
  <div className="flex flex-col h-full">
    <ToolbarHeaderControls />
    <Toolbar layout="vertical" />
  </div>
), []);
```

## Height/Width Calculations

### Horizontal (Portrait Footer)

```
SecondaryPanel CONTENT_HEIGHT: 96px
- Header controls: ~32px
- Gap: 4px
- Available for grid: ~60px
- Single row: 60px height (exceeds 48px minimum ✓)
```

### Vertical (Side Rail)

```
ContextRail expanded: 200px width
- Padding: ~16px
- Available: ~168px width
- Button: 48px height × full width
- Scrollable for overflow
```

## Swipe Paging (Horizontal Mode Only)

- Keep existing swipe gesture logic
- `SLOTS_PER_PAGE = 4` (single row)
- Page indicator: `1/3` format
- No paging in vertical mode (scroll instead)

## Default Actions

With 4 slots per page in horizontal mode:

- Page 1: Split, Glue, Delete, Marker
- Page 2: Ripple, Snap, Dupe, (empty)

Vertical mode shows all 7 actions in scrollable list.

## Testing Checklist

**Horizontal mode (portrait footer):**

- [ ] Single row of 4 buttons in 96px panel
- [ ] Buttons ≥48px height
- [ ] Swipe paging works
- [ ] Page indicator shows "1/2"

**Vertical mode (side rail):**

- [ ] Single column, 48px per button
- [ ] Scrollable when many buttons
- [ ] No swipe paging (scroll instead)
- [ ] Works in 200px expanded panel

**Grid mode (ActionsView):**

- [ ] Unchanged flex-wrap behavior
- [ ] Size prop still works (sm/md/lg)

**Transitions:**

- [ ] Portrait → landscape switch updates layout
- [ ] State preserved across layout changes

## Implementation Order

1. Update ToolbarButton with `layout` prop and LAYOUT_CONFIG
2. Update Toolbar with `layout` prop, change to single row (4 slots) for horizontal
3. Update TimelineView to pass `layout="horizontal"`
4. Clear localStorage and test fresh
5. (Future) Side rail integration passes `layout="vertical"`
