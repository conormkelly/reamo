# Frontend Cleanup Plan

## Context
REAmo frontend cleanup to establish a solid foundation before finalizing landscape/portrait orientation and side rail patterns. The goal is to eliminate debt that would pollute LLM context and prevent bad patterns from being replicated.

**Key Constraint:** Side rail/dual-rail responsive patterns are NOT finalized - clean up the foundation without disrupting this evolving area.

---

## Current State (from exploration)

### What's Already Good (PRESERVE)
- Color design tokens: 150+ semantic tokens, mature system
- Feature-based folder structure: 88% of components in subdirectories
- Barrel exports in feature folders
- Modal/BottomSheet base components exist
- Layout constants centralized in `constants/layout.ts`
- Z-index scale defined
- Memory safety patterns documented with commit references

### Actual Debt Areas
| Area | Severity | Details |
|------|----------|---------|
| Spacing | HIGH | No semantic scale, 14+ ad-hoc padding values |
| Button primitives | MEDIUM | MuteButton, SoloButton, etc. duplicate logic; ActionButton exists but inconsistent use |
| Giant files | MEDIUM | 4 files >700 LOC (RoutingModal, Timeline, NavigateItemInfoBar, RegionInfoBar) |
| Input components | LOW | Only ColorPickerInput exists |
| Dead code | UNKNOWN | ~20 potentially unused components (needs verification) |
| Root-level files | LOW | 20 files at components/ root (most are legitimate) |

---

## Refined Phase Plan

### Phase 1: Inventory & Dead Code Analysis
**Goal:** Complete the inventory and identify confirmed dead code.

**Tasks:**
- [ ] Generate import analysis to find unused components
- [ ] Verify each flagged component is actually unused (check for dynamic imports, lazy loading)
- [ ] Create removal list with justification for each
- [ ] Remove confirmed dead code (with git history preserved)

**Output:** Clean codebase, documented in FRONTEND_CLEANUP.md

---

### Phase 2: Spacing Design Tokens
**Goal:** Establish semantic spacing scale before normalization.

**Tasks:**
- [ ] Define spacing scale in `index.css` @theme block:
  ```css
  --space-xs: 4px;   /* 0.25rem / p-1 */
  --space-sm: 8px;   /* 0.5rem / p-2 */
  --space-md: 12px;  /* 0.75rem / p-3 */
  --space-lg: 16px;  /* 1rem / p-4 */
  --space-xl: 24px;  /* 1.5rem / p-6 */
  --space-2xl: 32px; /* 2rem / p-8 */
  ```
- [ ] Add Tailwind utility mappings if needed
- [ ] Document scale rationale in FRONTEND_DEVELOPMENT.md
- [ ] Define semantic spacing tokens for common patterns:
  - `--space-modal-padding`
  - `--space-panel-padding`
  - `--space-button-padding-*` (sm/md/lg)

**Output:** Spacing vocabulary established, ready for normalization

---

### Phase 3: Button Primitive Unification
**Goal:** Create unified Button component with variants.

**Context from exploration:**
- `ActionButton.tsx` exists with size (sm/md/lg) and variant (default/primary/danger/ghost)
- Track buttons (Mute, Solo, RecordArm, Monitor) each have own className logic
- Transport buttons hardcoded to 44px square
- ToolbarButton has different pattern than ActionButton

**Tasks:**
- [ ] Audit all button patterns across codebase
- [ ] Design unified Button component API (sizes, variants, states)
- [ ] Implement Button primitive (or extend ActionButton)
- [ ] Migrate track buttons to use shared primitive (preserving current styling)
- [ ] Document button patterns in FRONTEND_DEVELOPMENT.md

**Output:** Single source of truth for button rendering

---

### Phase 4: Spacing Normalization
**Goal:** Apply new spacing tokens across codebase.

**Priority Order:**
1. Modal components (ModalContent, ModalFooter, ModalHeader)
2. Panel components (QuickActionsPanel, MarkerNavigationPanel, etc.)
3. List items (OverflowMenu items, selectors)
4. Track controls
5. Everything else

**Tasks:**
- [ ] Replace ad-hoc padding with spacing tokens, starting with highest-impact areas
- [ ] Verify visual consistency after each batch of changes
- [ ] Run app on device to check touch targets

**Output:** Consistent spacing throughout app

---

### Phase 5: Component Organization
**Goal:** Group root-level components into logical folders.

**Proposed structure:**
```
components/
  Core/           # ErrorBoundary, Portal, ViewLayout, ReaperProvider
  Layout/         # TabBar, ViewHeader
  Connection/     # ConnectionStatus, NetworkStatsModal, UpdateBanner
  Overlays/       # ModalRoot, OrientationHint
  Settings/       # SettingsMenu, TextSizeControl
  ...existing feature folders...
```

**Tasks:**
- [ ] Create new folders
- [ ] Move files, update imports
- [ ] Add barrel exports (index.ts) for new folders
- [ ] Update components/index.ts

**Output:** Logical grouping, cleaner imports

---

### Phase 6: Giant Component Analysis (Per-Component Decision)
**Goal:** Analyze large components and decide extraction strategy.

**Target files:**
| File | LOC | Notes |
|------|-----|-------|
| Mixer/RoutingModal.tsx | 1,318 | Complex routing configuration, multiple tabs |
| Timeline/Timeline.tsx | 1,264 | Main timeline view, hooks already extracted |
| Timeline/NavigateItemInfoBar.tsx | 829 | Info bar with navigation |
| Timeline/RegionInfoBar.tsx | 731 | Region information display |

**Approach:** Conservative - extract only obvious boundaries (e.g., tabs as separate components). Don't refactor working logic.

**Tasks:**
- [ ] Read each file, document structure
- [ ] Identify extraction candidates (sub-components, repeated patterns)
- [ ] Propose changes, get approval before executing
- [ ] Extract approved pieces only

**Output:** Per-component decision document, selective extractions

---

### Phase 7: Visual Polish (DEFERRED)
**Status:** Blocked until side rail design is finalized.

**Will include:**
- Touch target verification on actual devices
- Text hierarchy audit
- Loading/empty state consistency
- Transition/animation polish

---

## Quick Wins (Can Do Anytime)
- [ ] Add missing barrel exports for any folders without index.ts
- [ ] Move any remaining magic numbers to constants/
- [ ] Fix any TypeScript `useRef<T>()` patterns (should be `useRef<T>(null)`)

---

## Files to Create/Update
- `frontend/FRONTEND_CLEANUP.md` - Progress log for each phase
- `frontend/src/index.css` - Add spacing tokens (Phase 2)
- `frontend/FRONTEND_DEVELOPMENT.md` - Add spacing scale docs, button patterns
- New component folders as needed (Phase 5)

---

## Execution Model
- **One phase per session** - Clear handoff between each
- **Each phase ends with:** Working app, updated FRONTEND_CLEANUP.md, summary of findings
- **User reviews** before starting next phase
- **Estimated sessions:** 6-7 (Phase 7 deferred)

---

## Key Constraints
1. **Don't touch SideRail/ContextRail code** - Design not finalized
2. **Preserve existing patterns** - Barrel exports, color tokens, Modal/BottomSheet bases
3. **Test on device after visual changes** - Touch targets matter
4. **One concern per commit** - Keep changes reviewable
5. **No git commits** - User maintains git control (per CLAUDE.md)
