# Phase 3 - Button Primitive Unification: Execution Summary

## Overview

Phase 3 unifies the codebase's button patterns through targeted extraction of duplicated code, removal of dead code, and establishment of governance documentation. Unlike a "mega-Button primitive" approach, this phase follows the **Rule of Three** - only extracting patterns that appear 3+ times with stable interfaces.

## Sub-Phase Summary

| Phase | Focus | Files Changed | Files Deleted | LOC Impact | Risk |
|-------|-------|---------------|---------------|------------|------|
| **3.1** | Foundation & Dead Code | 3 | 6 | -521 | Low |
| **3.2** | CircularTransportButton | 3 | 0 | -50 (dedup) | Low |
| **3.3** | TrackControlButton Styling | 6 | 0 | -25 (dedup) | Medium |
| **3.4** | Documentation & Governance | 1 | 0 | +200 (docs) | None |
| **Total** | | 13 | 6 | **~-400 LOC net** | Low-Medium |

## Recommended Execution Order

```
Phase 3.1 (Foundation)
    ↓
Phase 3.2 (CircularTransportButton)
    ↓
Phase 3.3 (TrackControlButton)
    ↓
Phase 3.4 (Documentation)
```

**Dependencies:**
- 3.2 depends on 3.1 (uses control height tokens)
- 3.3 depends on 3.1 (uses control height tokens)
- 3.4 depends on 3.1-3.3 (documents what was built)
- 3.2 and 3.3 are independent of each other (could run in parallel)

## Total Scope

### Files Deleted (6 files, ~521 LOC)
| File | LOC | Reason |
|------|-----|--------|
| ActionButton.tsx | 94 | Dead code - zero imports |
| ToggleButton.tsx | 97 | Dead code - zero imports |
| ActionButton.test.tsx | 225 | Tests for dead code |
| PlayButton.tsx | 35 | Superseded by inline TransportButton |
| StopButton.tsx | 35 | Superseded by inline TransportButton |
| RecordButton.tsx | 35 | Superseded by inline TransportButton |

### Files Created (2 files)
| File | LOC | Purpose |
|------|-----|---------|
| CircularTransportButton.tsx | ~50 | Unified transport button component |
| trackControlStyles.ts | ~20 | Shared track button styling utilities |

### Files Modified (11 files)
| File | Changes |
|------|---------|
| index.css | Add control height + intent variant tokens |
| Actions/index.ts | Remove dead exports |
| Transport/index.ts | Remove dead exports, add CircularTransportButton |
| TransportBar.tsx | Use CircularTransportButton |
| PersistentTransport.tsx | Use CircularTransportButton |
| MuteButton.tsx | Use shared styling utilities |
| SoloButton.tsx | Use shared styling utilities |
| RecordArmButton.tsx | Use shared styling utilities |
| MonitorButton.tsx | Use shared styling + fix accessibility |
| MasterMonoButton.tsx | Use shared styling utilities |
| FRONTEND_DEVELOPMENT.md | Add button system documentation |

### Token Additions (index.css)
```css
/* Control heights */
--size-control-sm: 32px;
--size-control-md: 40px;
--size-control-lg: 44px;
--size-control-xl: 48px;
--size-touch-target-min: 44px;

/* Intent variants */
--color-intent-primary-bg, --color-intent-primary-hover
--color-intent-danger-bg, --color-intent-danger-hover
--color-intent-success-bg, --color-intent-success-hover
--color-intent-secondary-bg, --color-intent-secondary-hover
```

## Decisions Needed Before Starting

### 1. React Aria Dependency

**Question:** Should we add React Aria (~30KB gzipped) for better button behavior?

**Recommendation:** **No, skip for now.**

The research recommended React Aria's `useButton`, but our buttons are simple enough that native `<button>` with `aria-pressed` and `aria-label` is sufficient. Add React Aria later if we need:
- Complex press event normalization
- Advanced focus management
- Disabled state handling beyond CSS

### 2. Density Modes

**Question:** Should we implement user-selectable Compact/Normal/Accessible density modes?

**Recommendation:** **Defer to visual polish phase.**

Track buttons are 24-36px, below Apple's 44px minimum. The research recommends density modes (like Cubasis's mixer zoom). However:
- Requires UI for mode selection
- Affects layout calculations throughout mixer
- Better suited for a dedicated "accessibility & density" phase

**Document the compromise** in Phase 3.4 and revisit later.

### 3. ESLint Rules

**Question:** Should we implement custom ESLint rules to enforce button patterns?

**Recommendation:** **Document as future work, don't implement now.**

- Custom ESLint plugins add maintenance burden
- Codebase is small enough for code review
- TypeScript props provide some guardrails

If drift becomes a problem in 3-6 months, revisit.

### 4. Non-Color Indicators

**Question:** Should we add icons/text labels to track buttons for colorblind users?

**Recommendation:** **Document as future work.**

- Mute/Solo already have text labels ("M", "S")
- RecordArm/Monitor use icons, could add text
- Better suited for dedicated accessibility audit

## Success Criteria

After all phases complete:

1. **Build passes:** `npm run build` succeeds
2. **Tests pass:** `npm test` succeeds (with fewer tests after ActionButton.test.tsx removal)
3. **Visual parity:** All buttons look identical to before
4. **Functionality preserved:** All button interactions work correctly
5. **Accessibility improved:** MonitorButton announces state changes to screen readers
6. **Documentation complete:** FRONTEND_DEVELOPMENT.md has button best practices
7. **Dead code removed:** No unused button components remain

## Quick Reference: Plan Files

| File | Description |
|------|-------------|
| [FRONTEND_CLEANUP_PHASE_3.1_PLAN.md](./FRONTEND_CLEANUP_PHASE_3.1_PLAN.md) | Foundation & Dead Code |
| [FRONTEND_CLEANUP_PHASE_3.2_PLAN.md](./FRONTEND_CLEANUP_PHASE_3.2_PLAN.md) | CircularTransportButton |
| [FRONTEND_CLEANUP_PHASE_3.3_PLAN.md](./FRONTEND_CLEANUP_PHASE_3.3_PLAN.md) | TrackControlButton Styling |
| [FRONTEND_CLEANUP_PHASE_3.4_PLAN.md](./FRONTEND_CLEANUP_PHASE_3.4_PLAN.md) | Documentation & Governance |

## Post-Execution

After each sub-phase, create an outcome document:
- `FRONTEND_CLEANUP_PHASE_3.X_OUTCOME.md`
- Document what was done, deviations from plan, commit message

After all phases complete:
- Archive findings document: `mv FRONTEND_CLEANUP_PHASE_3_FINDINGS.md docs/archive/`
- Archive research document: `mv research/BROWNFIELD_BUTTON_MIGRATION.md docs/archive/`
- Update PLANNED_FEATURES.md to mark Phase 3 complete

---

## Appendix: Research Insights Applied

| Research Recommendation | How Applied |
|------------------------|-------------|
| Delete dead ActionButton/ToggleButton | Phase 3.1 |
| Use shared `--control-height-*` tokens, NOT per-button | Phase 3.1 |
| React Aria + CVA for specialized buttons | Deferred - native buttons sufficient |
| Touch target minimum 44px | Documented as known compromise |
| Tri-state toggles: radio group or cycling with live region | Phase 3.3 (MonitorButton) |
| Governance through TypeScript + ESLint | Partial - TypeScript only for now |
| Rule of Three for extraction | Applied throughout |
| Strangler Fig pattern | Applied - migrate incrementally |
