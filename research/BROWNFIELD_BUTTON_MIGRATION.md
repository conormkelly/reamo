# Validating your brownfield button migration strategy

Your proposed "targeted shared components" approach is **strongly validated** by industry best practices. The strategy of creating `CircularTransportButton` and `TrackControlButton` rather than a mega-Button primitive aligns with the "Wrong Abstraction" principle (Sandi Metz) and avoids the prop explosion anti-pattern that plagues monolithic component systems. Delete the unused `ActionButton`/`ToggleButton`—dead code compounds technical debt and confuses new developers.

The research reveals a clear architectural recommendation for your specialized audio PWA: **React Aria hooks for behavior + class-variance-authority (CVA) for styling**. This headless approach gives you maximum control over touch targets, custom interactions, and domain-specific ARIA labeling while ensuring accessibility compliance.

---

## The right abstraction level prevents shotgun surgery

Your instinct to avoid a single mega-Button is correct. The research shows that monolithic components with extensive props configuration become "slow, risky to change, and don't compose well." The pattern you're describing—extracting `CircularTransportButton` and `TrackControlButton` as targeted shared components—follows the **Rule of Three**: don't abstract until a pattern appears 3+ times with stable, similar interfaces.

**Decision framework for extraction:**
Extract to shared component when the pattern appears 3+ times across the codebase, the interface is primitive and stable, and multiple features benefit from consistency. Leave specialized when only 1-2 similar usages exist, use cases have subtle but meaningful differences, or the component is tightly coupled to feature logic. Your `ToolbarButton` and `QuickActionsPanel` likely fall in the "leave specialized" category since they're feature-specific and don't suffer from the **25 LOC duplication** you've identified in track controls.

The **Strangler Fig pattern** applies beautifully here: build new targeted components alongside legacy ones, migrate feature-by-feature starting with lowest-risk areas, deprecate gradually, and remove legacy only when zero usages remain. Tie each migration to a feature or bug fix to demonstrate value—"refactoring for the sake of refactoring can easily lead to accusations of misused time."

---

## React Aria hooks solve the specialization problem

For a mobile-first audio PWA with specialized button types, **headless primitives win decisively** over styled libraries like Chakra or Material UI. Styled libraries optimize for common patterns, but transport controls, track buttons, and mixer UIs require exact touch target sizing, custom visual feedback, multi-touch interactions, and domain-specific ARIA labeling that generic button styles fight against.

The recommended architecture stacks behavior, styling, and domain logic cleanly:

```typescript
// hooks/useAudioButton.ts - React Aria provides the foundation
import { useButton } from 'react-aria';

export function useAudioButton(props) {
  const ref = useRef(null);
  const { buttonProps, isPressed } = useButton({
    ...props,
    onPressStart: (e) => {
      if (e.pointerType === 'touch') navigator.vibrate?.(10);
    },
  }, ref);
  return { buttonProps, isPressed, ref };
}
```

CVA (class-variance-authority) handles variants with type safety:

```typescript
const transportButtonStyles = cva(
  "rounded-full transition-all touch-manipulation active:scale-95",
  {
    variants: {
      action: {
        play: "bg-green-500 hover:bg-green-400",
        stop: "bg-red-500 hover:bg-red-400", 
        record: "bg-red-600 hover:bg-red-500",
      },
      size: {
        sm: "w-10 h-10",
        md: "w-14 h-14",
        lg: "w-20 h-20",
      },
    },
  }
);
```

**Key insight from React Aria**: use `isPressed` for visual feedback instead of CSS `:active`—React Aria handles the edge case where users drag off a button before releasing, which CSS alone cannot detect properly.

---

## Touch targets require a multi-density strategy

Apple HIG specifies **44×44pt minimum** with no documented exceptions for professional apps. However, every major professional audio app—TouchOSC, Lemur, Cubasis, Logic Remote—implements some form of **user-controlled density modes**. Your current 24-36px targets violate HIG and will cause approximately **25% tap error rates**, particularly affecting users with motor impairments.

**Cubasis provides the best model**: three mixer zoom levels plus full-screen mode, allowing users to choose their density/accuracy tradeoff. Logic Remote takes a different approach with "Smart Controls" that abstract complex plugin UIs into touch-friendly interfaces rather than forcing desktop UI onto touch.

Implement explicit touch target tokens:

```css
:root {
  /* Core targets */
  --touch-target-min: 44px;           /* Apple HIG minimum - default */
  --touch-target-comfortable: 48px;    /* Primary actions */
  --touch-target-accessible: 64px;     /* Enhanced accessibility mode */
  
  /* Pro mode (explicit user opt-in) */
  --touch-target-compact: 36px;        /* Below HIG - warning in settings */
  
  /* Spacing */
  --touch-target-gap-min: 8px;
}
```

For visual elements currently at 24-36px, use **tappable area extension**—the icon can remain small while the hit area extends to meet minimums through padding. WCAG 2.2's spacing exception also helps: targets can be smaller than 24px if they have 24px spacing from adjacent targets.

---

## Token architecture follows a three-tier pattern

All four major design systems (Polaris, Primer, Spectrum, Carbon) use **three-tier token architecture**: primitive → semantic/functional → component-specific. The critical insight is that **button-specific tokens should exist only for colors and shadows**, not dimensions.

```css
/* Layer 1: Primitive tokens */
--size-8: 2rem;      /* 32px */
--size-10: 2.5rem;   /* 40px */
--size-12: 3rem;     /* 48px */

/* Layer 2: Semantic control tokens (shared by button, input, select) */
--control-height-sm: var(--size-8);
--control-height-md: var(--size-10);
--control-height-lg: var(--size-12);

/* Layer 3: Component tokens (colors only) */
--btn-primary-bg: var(--color-brand-500);
--btn-mute-active: var(--color-blue-500);
--btn-solo-active: var(--color-yellow-400);
--btn-arm-active: var(--color-red-500);
```

**Don't create** `--btn-padding-sm` or `--btn-height-md`—use the shared `--control-*` tokens. This ensures buttons pair correctly with inputs (32px buttons with 32px inputs) and maintains system-wide consistency. Only Spectrum uses per-button-size tokens, and their system is notably complex.

---

## Tri-state toggles require radio groups, not aria-pressed

Your binary toggles (mute on/off, solo on/off) correctly use `aria-pressed`. However, for **cycling toggles with three states** (off → on → auto), `aria-pressed="mixed"` is **not the correct pattern**—that value indicates "multiple controlled items have different states," like a "Select All" checkbox.

For tri-state cycling toggles, use either radio groups:

```html
<div role="radiogroup" aria-label="Monitor mode">
  <button role="radio" aria-checked="false">Off</button>
  <button role="radio" aria-checked="true">On</button>
  <button role="radio" aria-checked="false">Auto</button>
</div>
```

Or a single button with changing label plus live region:

```html
<button aria-label="Monitor mode: Auto">Auto</button>
<div aria-live="polite" class="sr-only">Monitor mode changed to Auto</div>
```

**Color reliance for track buttons** (mute=blue, solo=yellow, arm=red) violates WCAG 1.4.1. Add text labels ("M", "S", "R"), distinct icons, or shape differentiation alongside color. Position-based meaning also helps—mute always leftmost creates spatial memory.

---

## Delete the dead code, consolidate the variant systems

**Delete `ActionButton`/`ToggleButton` immediately.** Goldman Sachs Engineering and multiple sources emphasize that unused code "directly impacts velocity, convolutes the codebase for new developers, and compounds as technical debt." If concepts from those components are valuable, extract them to documentation before deletion. Git history preserves the code if ever needed.

For the **ModalFooter variant duplication** (`confirmVariant: 'primary' | 'danger' | 'success'`), create **one canonical variant system** at the semantic layer:

```typescript
type IntentVariant = 'primary' | 'secondary' | 'danger' | 'success';

// Both ModalFooter and ActionButton reference the same source
const intentClasses: Record<IntentVariant, string> = {
  primary: "bg-blue-600 text-white",
  secondary: "bg-gray-100 text-gray-900", 
  danger: "bg-red-600 text-white",
  success: "bg-green-600 text-white",
};
```

View header button variation is acceptable if the variations serve distinct UX purposes—not every button needs to share a primitive. Apply the Rule of Three.

---

## Governance through constraints, not documentation alone

Documentation patterns that **actually get followed** are those enforced in-editor. ESLint rules surface in the IDE immediately; type constraints prevent incorrect usage at compile time. Written documentation has low compliance rates unless paired with automated enforcement.

Create custom ESLint rules for your design system:

```javascript
// eslint-plugin-design-system
module.exports = {
  rules: {
    'prefer-ds-button': {
      create(context) {
        return {
          JSXOpeningElement(node) {
            if (node.name.name === 'button') {
              context.report({
                node,
                message: 'Use design system Button component instead of native button',
              });
            }
          }
        };
      }
    }
  }
};
```

TypeScript provides the strongest "pit of success" pattern—constrain variants to literal types, not arbitrary strings:

```typescript
// Wrong: Too flexible
<Button color="any-string" />

// Right: Constrained
<Button variant="primary" | "secondary" | "danger" />
```

**Governance process for new variants**: use what exists → contact DS owner → determine if one-off or system-wide → if one-off, create local variant with isolation → if system-wide, propose through formal process → document and communicate.

---

## Recommended implementation sequence

**Phase 3.1 (Foundation, 1-2 weeks)**: Extract shared tokens from existing 15 button files. Create `useAudioButton` hook wrapping React Aria. Establish `--control-height-*` and intent variant tokens. Delete `ActionButton`/`ToggleButton`.

**Phase 3.2 (Targeted components, 2-3 weeks)**: Build `CircularTransportButton` with CVA variants. Build `TrackControlButton` with proper accessibility (aria-pressed, non-color indicators). Implement touch target token system with default HIG-compliant mode.

**Phase 3.3 (Incremental migration)**: Apply Strangler Fig—migrate one screen at a time starting with lowest-risk areas. Consolidate ModalFooter variants into canonical system. Add ESLint rules to prevent new raw `<button>` usage.

**Phase 3.4 (Density modes)**: Add user-selectable Compact/Normal/Accessible modes following Cubasis model. Implement tappable area extension for compact mode with explicit settings warning.

---

## Conclusion

Your targeted shared component approach is architecturally sound—the research validates avoiding mega-Button primitives and confirms that specialized audio apps benefit from headless primitives (React Aria) over styled libraries. The key additions to your strategy should be: mandatory touch target compliance with user-controlled density modes, three-tier token architecture using shared `--control-*` sizing tokens, proper tri-state toggle patterns using radio groups instead of `aria-pressed="mixed"`, and governance through TypeScript constraints and custom ESLint rules rather than documentation alone. Delete the dead code immediately—it provides no option value and increases cognitive load for every developer who encounters it.
