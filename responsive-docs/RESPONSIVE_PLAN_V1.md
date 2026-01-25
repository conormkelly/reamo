# Responsive Side Rail Implementation Plan

**Branch:** `refactor/responsive-frontend`
**Goal:** Implement side rail navigation for landscape-constrained phones, converting 148px vertical chrome into 72px horizontal chrome.

---

## Problem Statement

Phone landscape viewport (~390px height) loses 38% to bottom chrome:
- TabBar: 48px
- PersistentTransport: 56px
- SecondaryPanel: 44-140px
- **Result:** Only 100-200px for actual content

**Solution:** When `height < 480px` AND `width > height`, move navigation + transport to 72px side rail on left edge.

---

## Design Decisions (User Confirmed)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Phone landscape approach | Full side rail | Not placeholder - proper implementation |
| SecondaryPanel handling | **Integrate into side rail** | Bank nav, actions, info access are critical functionality |
| Bank navigation | Include in side rail | Quick track switching needed |
| Header height | Keep 44px for now | Revisit after higher ROI fixes; document for later sweep |
| Test devices | Both iOS + Android | Height threshold 480px works for both |
| iPad focus | Later phase | Build infrastructure now that extends without rework |

---

## Implementation Phases

### Phase 1: Core Infrastructure

**1.1 Create `useLayoutContext` hook**
```
File: frontend/src/hooks/useLayoutContext.ts
```
- Returns: `{ widthClass, heightClass, navPosition, isLandscapeConstrained, viewport }`
- Width classes: `compact` (<600px), `medium` (600-839px), `expanded` (≥840px)
- Height classes: `compact` (<480px), `regular` (≥480px)
- `navPosition`: `'side'` when landscape-constrained, else `'bottom'`
- Debounced resize + orientationchange listeners

**1.2 Add layout constants**
```
File: frontend/src/constants/layout.ts
```
Add:
- `SIDE_RAIL_WIDTH = 72`
- `HEIGHT_COMPACT_THRESHOLD = 480`
- `WIDTH_MEDIUM_THRESHOLD = 600`
- `WIDTH_EXPANDED_THRESHOLD = 840`

**1.3 Add CSS utilities**
```
File: frontend/src/index.css
```
- Height media query: `@media (max-height: 480px) and (orientation: landscape)`
- Side rail safe area: `.safe-area-left` for notch handling
- Z-index token for side rail

---

### Phase 2: SideRail Component

**2.1 Create SideRail component**
```
File: frontend/src/components/SideRail/SideRail.tsx
```

**Structure (72px wide):**
```
┌──────────┐
│ View Tabs │  ← 7 tabs, vertical scroll if needed
│ (icons)   │
│           │
├──────────┤
│ Bank Nav  │  ← Compact: "3/12" + ◀ ▶ arrows
├──────────┤
│ Actions   │  ← View-specific quick actions (expandable)
├──────────┤
│ Transport │  ← Play/Stop/Record buttons
└──────────┘
```

**Key features:**
- View navigation: 7 tab icons vertically stacked (reuse TabBar logic)
- Bank navigation: Compact display from `useBankNavigation` hook
- Actions/Info: Quick access button that opens BottomSheet with current view's controls
- Transport: Play/Pause, Stop, Record buttons (reuse PersistentTransport logic)
- Safe area: `padding-left: env(safe-area-inset-left)` for notch

**2.2 Create SideRailBankNav subcomponent**
```
File: frontend/src/components/SideRail/SideRailBankNav.tsx
```
- Compact bank indicator: "3/12"
- Prev/Next arrows
- Uses existing `useBankNavigation` hook

**2.3 Create SideRailActions subcomponent**
```
File: frontend/src/components/SideRail/SideRailActions.tsx
```
- Icon button that opens view-specific BottomSheet
- Mixer: TrackInfoBar in BottomSheet
- Timeline: Info/Toolbar tabs in BottomSheet
- Reuses existing InfoBar components

---

### Phase 3: App Layout Integration

**3.1 Modify App.tsx**
```
File: frontend/src/App.tsx
```

Changes:
- Import `useLayoutContext` and `SideRail`
- Conditional layout based on `navPosition`:

```tsx
// When navPosition === 'bottom' (current behavior)
<div className="flex flex-col h-dvh">
  <main>{view}</main>
  <TabBar />
  <PersistentTransport />
</div>

// When navPosition === 'side' (new)
<div className="flex flex-row h-dvh">
  <SideRail currentView={...} onViewChange={...} />
  <main className="flex-1">{view}</main>
</div>
```

- Hide TabBar and PersistentTransport when `navPosition === 'side'`
- Move `safe-area-x` from root to main content when side rail active
- Handle `RecordingActionsBar` positioning for side rail mode

**3.2 Update ViewLayout pattern**
Views using ViewLayout don't need changes - they measure container which will be correctly sized.

---

### Phase 4: View Integration (Mixer + Timeline)

**4.1 Update useAvailableContentHeight**
```
File: frontend/src/hooks/useAvailableContentHeight.ts
```
- Add `navPosition` and `isLandscapeConstrained` to return type
- Container measurement already works (ResizeObserver measures actual container)
- Views use these flags to adjust their internal behavior

**4.2 MixerView adjustments**
```
File: frontend/src/views/mixer/MixerView.tsx
```
- When `isLandscapeConstrained`:
  - Hide SecondaryPanel (functionality moved to side rail)
  - Keep using MixerStripCompact (faders will be taller with reclaimed space)
  - TrackDetailSheet still available via side rail "info" button

**4.3 TimelineView adjustments**
```
File: frontend/src/views/timeline/TimelineView.tsx
```
- When `isLandscapeConstrained`:
  - Hide SecondaryPanel (functionality in side rail)
  - Canvas gets more vertical space
  - Info/Toolbar accessible via side rail BottomSheet

---

## Critical Files to Modify

| File | Changes |
|------|---------|
| `frontend/src/hooks/useLayoutContext.ts` | **NEW** - Size class detection hook |
| `frontend/src/components/SideRail/SideRail.tsx` | **NEW** - Main side rail component |
| `frontend/src/components/SideRail/SideRailBankNav.tsx` | **NEW** - Compact bank navigation |
| `frontend/src/components/SideRail/SideRailActions.tsx` | **NEW** - Quick actions button |
| `frontend/src/components/SideRail/index.ts` | **NEW** - Barrel export |
| `frontend/src/App.tsx` | Conditional row/column layout |
| `frontend/src/hooks/useAvailableContentHeight.ts` | Add navPosition to return |
| `frontend/src/constants/layout.ts` | Add side rail constants |
| `frontend/src/index.css` | Height media queries, safe area utils |
| `frontend/src/views/mixer/MixerView.tsx` | Hide SecondaryPanel when side rail |
| `frontend/src/views/timeline/TimelineView.tsx` | Hide SecondaryPanel when side rail |
| `frontend/src/components/index.ts` | Export SideRail |
| `frontend/src/hooks/index.ts` | Export useLayoutContext |

---

## Implementation Order

```
1. useLayoutContext hook (foundation - everything depends on this)
2. Layout constants
3. CSS utilities
4. SideRail component (basic: nav tabs + transport)
5. App.tsx layout switching
6. Test basic side rail works
7. SideRailBankNav (bank navigation)
8. SideRailActions (info/toolbar access via BottomSheet)
9. MixerView integration (hide SecondaryPanel)
10. TimelineView integration
11. Polish + edge cases
```

---

## Testing Checklist

**Manual Testing:**
- [ ] iPhone SE landscape (568×320) - triggers side rail
- [ ] iPhone 14 Pro landscape (852×393) - triggers side rail
- [ ] iPhone 14 Pro Max landscape (932×430) - triggers side rail
- [ ] iPad mini portrait (744×1133) - stays bottom nav
- [ ] Rotation transitions - smooth switch
- [ ] PWA standalone mode - safe areas work
- [ ] Bank navigation works in side rail
- [ ] Info/Toolbar accessible via side rail button
- [ ] Transport controls work in side rail

**E2E Tests:**
```typescript
test('shows side rail when height < 480px and landscape', async ({ page }) => {
  await page.setViewportSize({ width: 850, height: 400 });
  await expect(page.locator('[data-testid="side-rail"]')).toBeVisible();
  await expect(page.locator('[data-testid="tab-bar"]')).not.toBeVisible();
});
```

---

## iPad Extension (Future Phase)

The infrastructure scales to iPad without rework:
- iPad heights are always `regular` (well above 480px)
- `navPosition` stays `'bottom'` on iPad
- Future: When `widthClass === 'expanded'`, could show permanent side rail + bottom transport
- These are additive changes, no rework required

---

## Deferred Decisions

| Item | Status | Revisit When |
|------|--------|--------------|
| Header height 44px → 36px in landscape | Deferred | After side rail implemented, during polish sweep |
| Other views (Instruments, Notes, etc.) | Deferred | After Mixer + Timeline working |
| iPad-specific optimizations | Future phase | After phone landscape complete |

---

## Space Savings Analysis

**Current phone landscape (390px viewport):**
```
Header:           44px
Content:         ~100px (!)
SecondaryPanel:   44px
TabBar:           48px
Transport:        56px
Safe area:       ~34px
```

**With side rail (same 390px):**
```
Header:           44px
Content:         ~312px (3x more!)
Safe area:       ~34px

Side rail takes 72px horizontal (acceptable trade-off)
```

---

## Reference

- Research: `docs/architecture/RESPONSIVE_FRONTEND_FINAL.md`
- Bug catalog: `features/FRONTEND_SWEEP_V1.md`
- Existing responsive system: `RESPONSIVE_TIMELINE_AND_MIXER.md`
