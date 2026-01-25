# Phase 3.1 Outcome - Foundation & Dead Code Removal

**Date:** 2025-01-25
**Status:** Complete

## What Was Done

### Dead Files Deleted (6 files, ~521 LOC)

| File | LOC | Confirmed Unused Via |
|------|-----|---------------------|
| `Actions/ActionButton.tsx` | 94 | grep - only self-refs and test imports |
| `Actions/ToggleButton.tsx` | 97 | grep - only self-refs and test imports |
| `Actions/ActionButton.test.tsx` | 225 | Tests for deleted components |
| `Transport/PlayButton.tsx` | 35 | grep - zero imports |
| `Transport/StopButton.tsx` | 35 | grep - zero imports |
| `Transport/RecordButton.tsx` | 35 | grep - zero imports |

### Barrel Exports Updated (2 files)

- `Actions/index.ts` - Removed ActionButton, ToggleButton exports
- `Transport/index.ts` - Removed PlayButton, StopButton, RecordButton exports

### Tokens Added to index.css

**Control Height Tokens:**
```css
--size-control-sm: 2rem;           /* 32px */
--size-control-md: 2.5rem;         /* 40px */
--size-control-lg: 2.75rem;        /* 44px - Apple HIG minimum */
--size-control-xl: 3rem;           /* 48px */
--size-touch-target-min: 2.75rem;  /* 44px - reference */
```

**Intent Variant Tokens:**
```css
--color-intent-primary-bg, --color-intent-primary-hover
--color-intent-danger-bg, --color-intent-danger-hover
--color-intent-success-bg, --color-intent-success-hover
--color-intent-secondary-bg, --color-intent-secondary-hover
```

## Verification Results

- **Build:** Passed (890.80 kB bundle)
- **Tests:** 900/904 passed
  - 4 pre-existing failures in Timeline.test.tsx (playhead viewport calculations)
  - Unrelated to button changes

## Deviations from Plan

None - executed exactly as planned.

## Follow-up Notes

1. **Pre-existing test failures:** 4 tests in Timeline.test.tsx fail (playhead positioning). These should be investigated in a separate effort.

2. **Accessibility audit:** Per user decision, defer non-color indicator additions to a dedicated accessibility audit phase.

3. **Density modes:** Control height tokens are now in place. This enables future density mode implementation (user can select Compact/Normal/Accessible button sizes).

## Suggested Commit Message

```
refactor(frontend): remove dead button primitives, add control tokens

Delete ActionButton, ToggleButton (unused despite having tests) and
standalone transport buttons (superseded by inline TransportButton).

Add control height tokens (--size-control-sm/md/lg/xl) following
three-tier pattern from Shopify Polaris. These shared tokens enable
future density modes and will be used by CircularTransportButton
and TrackControlButton in Phase 3.2-3.3.

- 6 files deleted (~521 LOC)
- Control height + intent variant tokens added to index.css
- Barrel exports updated

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
```
