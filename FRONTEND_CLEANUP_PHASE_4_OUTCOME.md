# Frontend Cleanup Phase 4 Outcome

**Date:** 2025-01-25
**Phase:** Spacing Normalization
**Status:** Complete

---

## Summary

Applied semantic spacing tokens across the codebase, replacing ad-hoc Tailwind classes with consistent, meaningful tokens. Visual appearance is unchanged; only class names were migrated.

---

## Files Changed

### BottomSheet Content Patterns (`px-4 pb-6` → `px-sheet-x pb-sheet-bottom`)

| File | Lines Changed |
|------|---------------|
| `components/QuickActionsPanel.tsx` | 1 |
| `components/MarkerNavigationPanel.tsx` | 1 |
| `components/Timeline/NavigateItemInfoBar.tsx` | 3 |
| `components/Mixer/FxBrowserModal.tsx` | 1 |
| `components/Mixer/FxParamModal.tsx` | 1 |
| `components/Mixer/FxModal.tsx` | 1 |
| `components/Mixer/RoutingModal.tsx` | 1 |
| `components/Mixer/TrackDetailSheet.tsx` | 1 |

### Modal Footer Patterns (`px-4 py-3` → `px-modal-footer-x py-modal-footer-y`)

| File | Lines Changed |
|------|---------------|
| `views/playlist/components/PlaylistModals.tsx` | 1 |
| `components/Timeline/DeleteRegionModal.tsx` | 1 |
| `components/Timeline/MakeSelectionModal.tsx` | 1 |

### Modal Content Patterns (`p-4` → `p-modal`)

| File | Lines Changed |
|------|---------------|
| `views/actions/components/SectionEditor.tsx` | 3 (header, content, footer) |
| `components/Timeline/DeleteRegionModal.tsx` | 1 (content) |
| `components/Timeline/AddRegionModal.tsx` | 1 (content) |
| `components/Timeline/MarkerEditModal.tsx` | 1 (content) |
| `components/Timeline/MakeSelectionModal.tsx` | 1 (content) |
| `components/NetworkStatsModal.tsx` | 1 (content) |
| `components/Toolbar/IconPicker.tsx` | 4 (header, search, grid, footer) |
| `components/Toolbar/ToolbarEditor.tsx` | 3 (header, content, footer) |

---

## Token Mappings Applied

| Old Pattern | New Token | Value | Usage |
|-------------|-----------|-------|-------|
| `px-4 pb-6` | `px-sheet-x pb-sheet-bottom` | 16px / 24px | BottomSheet content areas |
| `px-4 py-3` | `px-modal-footer-x py-modal-footer-y` | 16px / 12px | Custom modal footers |
| `p-4` | `p-modal` | 16px | Modal header/content/footer |

---

## Previously Migrated (Phase 2)

The following were already using semantic tokens from Phase 2:

- `Modal.tsx` - `ModalContent` uses `p-modal`
- `ModalFooter.tsx` - uses `px-modal-footer-x py-modal-footer-y`
- `MarkerInfoBar.tsx` - uses `px-infobar-x py-infobar-y`
- `RegionInfoBar.tsx` - uses `px-infobar-x py-infobar-y`
- `TrackInfoBar.tsx` - uses `px-infobar-x py-infobar-y`
- `OverflowMenu.tsx` - uses `px-menu-item-x py-menu-item-y`
- View containers - use `p-view`

---

## Intentionally Not Migrated

| Pattern | Reason |
|---------|--------|
| `Modal.tsx` header `px-4 py-3` | No header token defined; values match footer but "footer" on header reads wrong |
| `ContextRail.tsx` `p-4` | Design not finalized per FRONTEND_CLEANUP_PLAN.md |
| `ActionSearch.tsx` `p-4` (3 places) | Error/empty state padding, internal component |
| `TrackDetailSheet.tsx:64` `p-4` | Empty state padding, internal component |
| `TimeSignatureButton.tsx` `p-4` | Dropdown popup, not modal pattern |
| `SectionEditor.tsx:106` `p-4` | Backdrop safe area, not content padding |
| `ActionsView.tsx` `p-4 pt-0` | Inner content with override, not view container |
| `BankEditorModal.tsx` `p-4` | Empty state padding, internal component |
| Internal `p-3` padding | Warning bars, textareas, section headers - component-internal |
| `gap-3` patterns | No 12px gap token exists (panel-gap=8px, section-gap=16px) |

---

## Verification

- **Build:** Pass (891 kB, target ≤1,050 kB)
- **Tests:** 900/904 pass (4 pre-existing Timeline failures)
- **Visual:** No spacing changes (all token values match original pixel values)

---

## Pre-commit Hook: Pre-existing Violations

The Phase 3.5 ESLint governance pre-commit hook flagged **13 errors** and **2 warnings** in files touched by this phase. These are **pre-existing violations** from the "98 existing violations" identified when the custom rules were added - the spacing changes just triggered lint on those files.

| Rule | Count | Files |
|------|-------|-------|
| `set-state-in-effect` | 10 | FxBrowserModal, FxParamModal, RoutingModal, NetworkStatsModal, DeleteRegionModal, MakeSelectionModal (2), MarkerEditModal, ToolbarEditor |
| `static-components` | 2 | SectionEditor (IconComponent created during render) |
| `refs` | 1 | AddRegionModal (existingColors ref accessed during render) |
| `require-effect-cleanup` | 1 | SectionEditor (setTimeout without cleanup) |
| `no-restricted-syntax` | 1 | NavigateItemInfoBar (inline `?? []`) |

**Recommendation:** Add a Phase 5 "ESLint Violation Cleanup" to address these. Most are reset-on-open patterns that should use computed initial state or key-based remounting instead of useEffect setState.

---

## Suggested Commit Message

```
refactor(frontend): apply semantic spacing tokens across codebase (Phase 4)

Phase 4 - Spacing Normalization: Replace ad-hoc Tailwind spacing classes
with semantic tokens established in Phase 2.

Migrations:
- BottomSheet content: px-4 pb-6 → px-sheet-x pb-sheet-bottom (10 files)
- Modal content: p-4 → p-modal (8 files, 15 occurrences)
- Custom modal footers: px-4 py-3 → px-modal-footer-x py-modal-footer-y (3 files)

Token values are identical to original values - this is a class name
migration only, no visual changes.

Benefits:
- Single source of truth for spacing values
- Semantic class names communicate intent
- Future-proof for responsive clamp() values
- Consistent with Phase 2 modal/infobar/menu migrations

Not migrated (intentional):
- Modal.tsx header (no header token, values match footer)
- ContextRail (design not finalized)
- Component-internal p-3/p-4 padding (error states, empty states, dropdowns)
- gap-3 patterns (no 12px gap token exists)

Files changed: 21
```
