# Phase 3.4 - Documentation & Governance

## Goal
Document button best practices and establish governance patterns to prevent future drift.

## Prerequisites
- Phase 3.1-3.3 complete (button system established)

## Files to Modify

### 1. `frontend/FRONTEND_DEVELOPMENT.md`

Add new section after "Design System (Design Tokens)" (approximately line 100):

---

```markdown
## 1a. Button System

### Control Height Tokens

All interactive controls (buttons, inputs, selects) use shared height tokens defined in `src/index.css`:

| Token | Value | Use Case |
|-------|-------|----------|
| `--size-control-sm` | 32px | Compact density mode |
| `--size-control-md` | 40px | Default controls |
| `--size-control-lg` | 44px | Touch-friendly (Apple HIG minimum) |
| `--size-control-xl` | 48px | Large touch targets |
| `--size-touch-target-min` | 44px | Reference for accessibility audits |

**Why shared tokens?** Buttons, inputs, and selects should align visually. Using `--size-control-md` everywhere ensures 40px buttons pair correctly with 40px inputs.

### Button Categories

| Category | Component | Usage |
|----------|-----------|-------|
| **Transport** | `CircularTransportButton` | Play, Stop, Pause, Record, Loop |
| **Track Controls** | `MuteButton`, `SoloButton`, etc. | Mixer strip toggles |
| **Modal Actions** | `ModalFooter` | Cancel/Confirm in dialogs |
| **Toolbar** | `ToolbarButton` | User-configurable action buttons |

### Intent Variants (Semantic Colors)

Use intent tokens for button colors, not raw color tokens:

```tsx
// Good - semantic intent
<button className="bg-intent-primary-bg hover:bg-intent-primary-hover">
  Save
</button>

// Avoid - raw colors (unless for domain-specific meaning like solo=yellow)
<button className="bg-primary hover:bg-primary-hover">
  Save
</button>
```

Intent tokens:
- `--color-intent-primary-*` - Primary actions (save, confirm)
- `--color-intent-danger-*` - Destructive actions (delete, cancel recording)
- `--color-intent-success-*` - Positive actions (keep, approve)
- `--color-intent-secondary-*` - Secondary/neutral actions

**Exception:** Domain-specific buttons (Mute=blue, Solo=yellow, Arm=red) use their semantic color tokens directly as they have established DAW meanings.

### Touch Targets

**Minimum:** 44×44px (Apple HIG). Track control buttons are currently smaller for density; this is a known compromise documented in the audit.

**Best practice:** Use `min-h-[--size-touch-target-min]` or `min-h-11` for touchable elements.

### Binary vs Tri-State Toggles

**Binary toggles** (on/off states): Use `aria-pressed`

```tsx
<button aria-pressed={isActive}>
  Toggle
</button>
```

**Tri-state toggles** (3+ states): Do NOT use `aria-pressed`. Instead:

```tsx
// Use aria-label with current state
<button aria-label={`Mode: ${currentState}`}>
  <Icon />
</button>

// Announce changes with live region
<span role="status" aria-live="polite" className="sr-only">
  {stateChangeAnnouncement}
</span>
```

Example: MonitorButton cycles Off → On → Auto. Using `aria-pressed` would be incorrect (screen readers wouldn't know the difference between On and Auto).

### Creating New Buttons

1. **Check existing components first** - Don't create a new button if an existing one fits
2. **Use shared styling utilities** - Import from `trackControlStyles.ts` for track buttons
3. **Follow the category pattern** - Transport? Use CircularTransportButton. Track control? Follow MuteButton pattern.
4. **Add accessibility** - `aria-pressed` for binary, `aria-label` + live region for multi-state

### DO NOT

- Create one-off button styles without checking existing patterns
- Use `aria-pressed` for toggles with more than 2 states
- Rely solely on color to indicate state (add icons, labels, or shape differences)
- Create buttons smaller than 32×32px (absolute minimum for any interactive element)
```

---

### 2. `frontend/FRONTEND_DEVELOPMENT.md` - Update Accessibility Section

Update Section 12 (Accessibility) to reference the new button patterns:

```markdown
## 12. Accessibility

### Toggle Button Patterns

**Binary toggles:** `aria-pressed="true|false"`
```tsx
<button aria-pressed={isActive}>Mute</button>
```

**Multi-state controls:** Don't use `aria-pressed`. Use `aria-label` and live regions:
```tsx
<button aria-label={`Monitor: ${state}`}>...</button>
<span role="status" aria-live="polite" className="sr-only">
  Monitor changed to {state}
</span>
```

See [Button System](#1a-button-system) for full patterns.

### Non-Color Indicators

Track buttons use domain-standard colors (mute=blue, solo=yellow, arm=red) which have accessibility concerns. Mitigations:
- Mute/Solo buttons have text labels ("M", "S")
- Position-based meaning (mute always leftmost)
- Active state has visual difference beyond color (brightness, fill)

**TODO:** Consider adding icons or shape indicators alongside color in future accessibility pass.
```

## Implementation Steps

1. **Update FRONTEND_DEVELOPMENT.md**
   - Add Section 1a "Button System" after Section 1
   - Update Section 12 "Accessibility" with toggle patterns
   - Update Table of Contents

2. **Create ESLint rule stub (optional - document as TODO)**

   Add to FRONTEND_DEVELOPMENT.md Section 22 (Deferred/Future Work):
   ```markdown
   ### ESLint Button Governance

   **Proposed rule:** Warn when using raw `<button>` elements in component files.

   ```javascript
   // eslint-plugin-reamo (future)
   'reamo/prefer-design-system-button': 'warn'
   ```

   This would encourage using `CircularTransportButton`, `ModalFooter`, etc. instead of ad-hoc button implementations.

   **Status:** Not yet implemented. Document as best practice for now.
   ```

3. **Verify documentation links**
   - All cross-references work
   - Table of Contents updated

## Documentation Additions Summary

| Document | Section | Content |
|----------|---------|---------|
| FRONTEND_DEVELOPMENT.md | §1a Button System | Token reference, categories, intent variants, touch targets, binary vs tri-state |
| FRONTEND_DEVELOPMENT.md | §12 Accessibility | Toggle patterns, non-color indicators |
| FRONTEND_DEVELOPMENT.md | §22 Deferred Work | ESLint rule stub |

## Testing Checklist

- [ ] Documentation renders correctly in markdown preview
- [ ] All internal links work
- [ ] Code examples are syntactically correct
- [ ] Table of Contents updated

## Risk Assessment

| Factor | Rating | Notes |
|--------|--------|-------|
| Risk Level | **None** | Documentation only |
| Files Changed | 1 | |
| Breaking Potential | None | |

## Decision: ESLint Rules

**Recommendation: Document as future work, don't implement now.**

Reasons:
1. Custom ESLint plugins add maintenance burden
2. Current codebase is small enough that code review catches issues
3. TypeScript props already provide some guardrails
4. Focus on completing the cleanup first

If drift becomes a problem after 3-6 months, revisit ESLint enforcement.

## Outcome Documentation

After execution, document in `FRONTEND_CLEANUP_PHASE_3.4_OUTCOME.md`:
- Sections added to FRONTEND_DEVELOPMENT.md
- Any clarifications needed during writing
- Suggested commit message:
  ```
  docs(frontend): add button system documentation and accessibility patterns

  New sections in FRONTEND_DEVELOPMENT.md:
  - §1a Button System: control height tokens, categories, intent variants,
    touch targets, binary vs tri-state toggle patterns
  - §12 Accessibility: updated toggle patterns, non-color indicator guidance

  Establishes governance documentation to prevent button pattern drift.
  ESLint enforcement documented as future work in §22.
  ```
