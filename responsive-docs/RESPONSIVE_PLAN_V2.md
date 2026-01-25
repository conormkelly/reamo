# Dual-Rail Responsive Layout Implementation Plan

**Branch:** `refactor/responsive-frontend`
**Goal:** Replace single cramped side rail with dual-rail layout for landscape-constrained phones.

---

## Problem Statement (Updated)

The initial side rail implementation (72px) crams too much into one vertical strip:
- 7 view tabs + bank nav + info button + 3 transport buttons = ~562px demand
- Available height on landscape phone: ~393px
- Result: Cramped controls, lost feature discoverability, inconsistent with portrait UX

**Solution:** Split into two rails:
- **Left Rail (60px):** Navigation tabs + Transport (global controls)
- **Right Rail (72px):** Bank nav + Tabs + Search (contextual tools, matches SecondaryPanel)

---

## Design Principles

1. **Consistency:** Right rail mirrors SecondaryPanel behavior (tabs, expand, content)
2. **Ergonomics:** Left thumb for nav, right thumb for context tools
3. **Discoverability:** Tab icons visible (not hidden behind single button)
4. **Space efficiency:** Content overlays rather than permanent panel expansion

---

## Target Layout (Landscape Constrained)

```
┌────────┬─────────────────────────────────────┬────────┐
│        │          Header (44px)              │        │
│  LEFT  ├─────────────────────────────────────┤ RIGHT  │
│  RAIL  │                                     │  RAIL  │
│ (60px) │          Main Content               │ (72px) │
│        │          (faders/timeline)          │        │
│  Nav   │                                     │ Tabs   │
│ Tabs   │                                     │ Bank   │
│   +    │                                     │ Nav    │
│ Trans  │                                     │ Search │
└────────┴─────────────────────────────────────┴────────┘
```

**Space Budget (iPhone 14 Pro, 852×393):**
- Left rail: 60px
- Right rail: 72px
- Content area: 720px (room for 6+ mixer strips)
- When right panel expands: overlays content (no reflow)

---

## Implementation Phases

### Phase 1: Slim Down Left Rail (NavRail)

**Goal:** Extract transport + nav into a minimal 60px rail.

**1.1 Rename and simplify SideRail → NavRail**
```
File: frontend/src/components/SideRail/SideRail.tsx → NavRail.tsx
```

Changes:
- Remove: SideRailBankNav, SideRailActions imports and usage
- Keep: View tabs (7 icons) + Transport controls (Play/Stop/Record)
- Reduce width: 72px → 60px
- Simplify: No bank nav state syncing needed

**1.2 Update layout constants**
```
File: frontend/src/constants/layout.ts
```

Add:
```typescript
export const NAV_RAIL_WIDTH = 60;
export const CONTEXT_RAIL_WIDTH = 72;
export const CONTEXT_PANEL_WIDTH = 200; // Expanded overlay width
```

**1.3 Delete unused subcomponents (defer until Phase 2 complete)**
```
Files to eventually remove:
- frontend/src/components/SideRail/SideRailBankNav.tsx
- frontend/src/components/SideRail/SideRailActions.tsx
```

---

### Phase 2: Create ContextRail Component

**Goal:** New right-side rail that mirrors SecondaryPanel behavior.

**2.1 Create ContextRail component**
```
File: frontend/src/components/ContextRail/ContextRail.tsx
```

Structure (72px wide, right edge):
```
┌──────────┐
│ Tab: Info│  ← Icon button, active state
├──────────┤
│Tab:Tools │  ← Only for Timeline view
├──────────┤
│ Search   │  ← Opens search sheet/expands
├──────────┤
│  spacer  │
├──────────┤
│    ◀     │  ← Bank back
│  1 / 3   │  ← Bank display (holdable)
│    ▶     │  ← Bank forward
├──────────┤
│  Expand  │  ← Chevron to show content panel
└──────────┘
```

Props:
```typescript
interface ContextRailProps {
  viewId: 'mixer' | 'timeline';
  tabs: ContextRailTabConfig[];
  bankNav: BankNavProps;
  search: SearchProps;
  className?: string;
}
```

**2.2 Create ContextRailTab subcomponent**
```
File: frontend/src/components/ContextRail/ContextRailTab.tsx
```

- Icon button with active/inactive states
- Badge support (dot or count)
- Matches SecondaryPanelTab styling

**2.3 Create ContextRailPanel (overlay)**
```
File: frontend/src/components/ContextRail/ContextRailPanel.tsx
```

- 200px wide overlay panel
- Slides from right edge when expanded
- Contains active tab's content
- Click-outside to dismiss
- Animated entrance/exit

**2.4 Create barrel export**
```
File: frontend/src/components/ContextRail/index.ts
```

Export: ContextRail, ContextRailTab, ContextRailPanel

---

### Phase 3: App Layout Integration

**3.1 Update App.tsx for dual-rail layout**
```
File: frontend/src/App.tsx
```

Change landscape layout from:
```tsx
<div className="flex flex-row h-dvh">
  <SideRail ... />
  <main>{view}</main>
</div>
```

To:
```tsx
<div className="flex flex-row h-dvh">
  <NavRail currentView={...} onViewChange={...} />
  <main className="flex-1 relative">{view}</main>
  <ContextRail viewId={currentView} tabs={...} bankNav={...} search={...} />
</div>
```

**3.2 Context rail state management**

Option A: Pass props from App (simpler, recommended for now)
- App reads from view-specific hooks or store
- Passes bankNav/search/tabs props to ContextRail

Option B: Store-based (like current sideRailSlice)
- Views populate store with their context
- ContextRail reads from store
- More decoupled but more complex

**Recommendation:** Start with Option A, refactor to B if needed.

**3.3 Handle ContextRail for non-Mixer/Timeline views**

For views without bank nav (Clock, Playlist, Actions, Notes, Instruments):
- ContextRail shows simplified version OR
- ContextRail hidden entirely (just NavRail)

Decision: Hide ContextRail for views that don't need it. They have full width.

---

### Phase 4: View Integration

**4.1 Update MixerView**
```
File: frontend/src/views/mixer/MixerView.tsx
```

Changes:
- Remove: Side rail state syncing (setSideRailBankNav, setSideRailInfo, etc.)
- Export: bankNavProps, searchProps, infoTabContent for App to pass to ContextRail
- OR: Create useMixerContextRail() hook that returns these

**4.2 Update TimelineView**
```
File: frontend/src/views/timeline/TimelineView.tsx
```

Changes:
- Remove: Side rail state syncing
- Export: bankNavProps, searchProps, tabs (info + toolbar) for ContextRail
- OR: Create useTimelineContextRail() hook

**4.3 Create context rail hooks (cleaner approach)**
```
File: frontend/src/hooks/useContextRailConfig.ts
```

```typescript
interface ContextRailConfig {
  tabs: ContextRailTabConfig[];
  bankNav: BankNavProps | null;
  search: SearchProps | null;
}

// Per-view hooks
function useMixerContextRail(): ContextRailConfig { ... }
function useTimelineContextRail(): ContextRailConfig { ... }

// Main hook that switches based on current view
function useContextRailConfig(viewId: ViewId): ContextRailConfig | null {
  // Returns null for views that don't need ContextRail
}
```

---

### Phase 5: Polish & Edge Cases

**5.1 Safe area handling**
- NavRail: `safe-area-left` for notch on left
- ContextRail: `safe-area-right` for notch on right (rare but possible)
- Both: `safe-area-top`, `safe-area-bottom`

**5.2 Orientation transition**
- Smooth transition when rotating device
- ContextRail panel should close on orientation change
- State should persist (which tab was active, etc.)

**5.3 Search behavior**
- Tap search icon → opens BottomSheet with search input
- OR: Inline expansion in rail (may be too narrow at 72px)
- Recommendation: BottomSheet for search, keeps rail simple

**5.4 Bank nav hold behavior**
- Timeline: Hold bank display to show track labels overlay
- Should work identically to SecondaryPanel behavior

**5.5 RecordingActionsBar positioning**
- Currently positioned above bottom safe area
- With dual rails: position between the two rails
- `left: 60px; right: 72px; bottom: safe-area`

---

## File Changes Summary

| File | Action | Description |
|------|--------|-------------|
| `components/SideRail/SideRail.tsx` | Rename → NavRail | Slim to 60px, nav + transport only |
| `components/SideRail/SideRailBankNav.tsx` | Delete | Moved to ContextRail |
| `components/SideRail/SideRailActions.tsx` | Delete | Moved to ContextRail |
| `components/SideRail/index.ts` | Update | Export NavRail |
| `components/ContextRail/ContextRail.tsx` | **NEW** | Right rail with tabs, bank nav, search |
| `components/ContextRail/ContextRailTab.tsx` | **NEW** | Tab button component |
| `components/ContextRail/ContextRailPanel.tsx` | **NEW** | Expandable content overlay |
| `components/ContextRail/index.ts` | **NEW** | Barrel export |
| `components/index.ts` | Update | Export ContextRail, update NavRail |
| `constants/layout.ts` | Update | Add NAV_RAIL_WIDTH, CONTEXT_RAIL_WIDTH |
| `hooks/useContextRailConfig.ts` | **NEW** | Per-view context rail configuration |
| `hooks/index.ts` | Update | Export useContextRailConfig |
| `App.tsx` | Update | Dual-rail layout integration |
| `views/mixer/MixerView.tsx` | Update | Remove side rail syncing |
| `views/timeline/TimelineView.tsx` | Update | Remove side rail syncing |
| `store/slices/sideRailSlice.ts` | Delete/Simplify | No longer needed if using prop-based approach |
| `store/index.ts` | Update | Remove sideRailSlice if deleted |

---

## Implementation Order

```
1. Update layout constants (NAV_RAIL_WIDTH, CONTEXT_RAIL_WIDTH)
2. Create ContextRail component (basic: tabs + bank nav)
3. Create ContextRailPanel (overlay with content)
4. Rename SideRail → NavRail, slim to 60px
5. Update App.tsx with dual-rail layout
6. Create useContextRailConfig hooks
7. Update MixerView (remove old syncing, use new pattern)
8. Update TimelineView (same)
9. Delete old SideRailBankNav, SideRailActions
10. Clean up sideRailSlice from store
11. Polish: safe areas, transitions, edge cases
```

---

## Testing Checklist

**Manual Testing:**
- [ ] iPhone SE landscape (568×320) - dual rails fit
- [ ] iPhone 14 Pro landscape (852×393) - primary target
- [ ] iPhone 14 Pro Max landscape (932×430) - extra width
- [ ] Rotation portrait ↔ landscape - smooth transition
- [ ] NavRail: all 7 view tabs accessible
- [ ] NavRail: transport controls work
- [ ] ContextRail: tabs switch content
- [ ] ContextRail: bank nav works (back/forward/display)
- [ ] ContextRail: expand shows content panel
- [ ] ContextRail: search opens sheet
- [ ] Content panel: click outside dismisses
- [ ] Timeline: hold bank display shows track labels
- [ ] RecordingActionsBar positioned correctly

**E2E Tests:**
```typescript
test('dual rail layout in landscape', async ({ page }) => {
  await page.setViewportSize({ width: 850, height: 400 });
  await expect(page.locator('[data-testid="nav-rail"]')).toBeVisible();
  await expect(page.locator('[data-testid="context-rail"]')).toBeVisible();
  await expect(page.locator('[data-testid="tab-bar"]')).not.toBeVisible();
});

test('context rail bank navigation', async ({ page }) => {
  await page.setViewportSize({ width: 850, height: 400 });
  await page.locator('[data-testid="context-rail-bank-forward"]').click();
  await expect(page.locator('[data-testid="context-rail-bank-display"]')).toContainText('2');
});
```

---

## Visual Reference

**Portrait (unchanged):**
```
┌─────────────────────────────┐
│         Header              │
├─────────────────────────────┤
│                             │
│       Main Content          │
│                             │
├─────────────────────────────┤
│ [i][T][Q]  ◀ 1/3 ▶  [v] │ ← SecondaryPanel
├─────────────────────────────┤
│       TabBar (7 tabs)       │
├─────────────────────────────┤
│    PersistentTransport      │
└─────────────────────────────┘
```

**Landscape (new dual-rail):**
```
┌──────┬───────────────────────┬──────┐
│      │        Header         │      │
│ NAV  ├───────────────────────┤CONTXT│
│ RAIL │                       │ RAIL │
│      │     Main Content      │      │
│[Time]│                       │ [i]  │
│[Mix] │                       │ [T]  │
│[Clk] │                       │ [Q]  │
│[List]│                       │      │
│[Act] │                       │  ◀   │
│[Note]│                       │ 1/3  │
│[Inst]│                       │  ▶   │
│──────│                       │──────│
│ [>]  │                       │ [v]  │
│ [O]  │                       │      │
│ [*]  │                       │      │
└──────┴───────────────────────┴──────┘
  60px                           72px
```

---

## Deferred Decisions

| Item | Status | Notes |
|------|--------|-------|
| Header height reduction (44→36px) | Deferred | Revisit after dual-rail working |
| ContextRail for other views | Deferred | Start with Mixer/Timeline only |
| Search inline vs sheet | Sheet | Simpler at 72px width |
| Store vs props for config | Props | Start simple, refactor if needed |

---

## Success Criteria

1. **Usable on iPhone landscape:** All controls accessible without cramming
2. **Consistent UX:** Right rail feels like rotated SecondaryPanel
3. **No feature regression:** Everything in portrait available in landscape
4. **Smooth transitions:** Rotation feels natural, panels animate
5. **Content space preserved:** Main area gets ~720px width minimum

---

## Reference

- Research: `docs/architecture/RESPONSIVE_FRONTEND_FINAL.md`
- Bug catalog: `features/FRONTEND_SWEEP_V1.md`
- Existing responsive system: `RESPONSIVE_TIMELINE_AND_MIXER.md`
