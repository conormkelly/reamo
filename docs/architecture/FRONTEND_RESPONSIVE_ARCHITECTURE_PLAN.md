# Responsive Architecture Implementation Plan

## Overview

This plan establishes world-class responsive PWA architecture for REAmo. It's designed for **one foundational agent** to complete Phase 1, enabling **multiple parallel agents** to work on Phase 2+ in separate git worktrees.

**Reference Documents**:

- [docs/architecture/UX_GUIDELINES.md](../../../docs/architecture/UX_GUIDELINES.md) - Responsive patterns and architecture
- [research/FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md](../../../research/FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md) - Production quality standards

---

## Agent Operating Principles

### 1. Measure Twice, Cut Once

**MANDATORY**: Before touching ANY code, every agent must:

1. **Deep exploration phase** - Read and understand ALL files in their scope
2. **Pattern discovery** - Use grep to find all instances of patterns they'll change
3. **Impact analysis** - Identify dependencies and downstream effects
4. **Document findings** - Note any surprises or deviations from expected patterns

Only after completing exploration should an agent write a single line of code.

### 2. Efficient Discovery via Grep

Agents should use targeted grep commands to efficiently find work items without reading entire files. This prevents context pollution and missed items.

**Standard discovery patterns for this refactor:**

```bash
# Find all view components
rg "export.*function.*View" --type tsx frontend/src/views/

# Find components missing flex-1 min-h-0 pattern
rg "flex-col" --type tsx frontend/src/ -l | xargs rg -L "min-h-0"

# Find hardcoded z-index values (need semantic replacement)
rg "z-\[?\d+\]?" --type tsx frontend/src/

# Find components using old h-screen-safe (should be h-dvh)
rg "h-screen-safe" --type tsx frontend/src/

# Find overflow handling patterns
rg "overflow-(auto|scroll|hidden)" --type tsx frontend/src/

# Find shrink-0 usage (verify chrome elements have it)
rg "shrink-0" --type tsx frontend/src/

# Find absolute positioning (potential layout issues)
rg "absolute" --type tsx frontend/src/components/ frontend/src/views/

# Find useRef without initial value (React 19 issue)
rg "useRef<[^>]+>\(\)" --type tsx frontend/src/

# Find potential memory leaks (timers without cleanup)
rg "setTimeout|setInterval" --type ts --type tsx frontend/src/ -l | xargs rg -L "clear"
```

### 3. Production Quality Standards

All agents must adhere to [research/FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md](../../../research/FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md):

| Checklist Area | Relevance to This Refactor |
|----------------|---------------------------|
| §1 Memory Safety | Verify cleanup in any new hooks (useMediaQuery, useContainerQuery) |
| §2 React 19 | Ensure useRef has initial values, no startTransition on layout updates |
| §3 Zustand 5 | Selectors must return stable references |
| §5 Touch Gestures | Verify touch-action on any new draggable elements |
| §6 PWA Safe Areas | Core focus of this refactor - verify all patterns |
| §8 Performance | No layout-thrashing animations, debounced ResizeObservers |

### 4. Verification Before Commit

Every agent must run these checks before considering their work complete:

```bash
# TypeScript compilation
npm run build

# Run tests (if they exist for touched files)
npm run test

# Grep audit for their specific area (examples below)
# Agent A (Timeline): rg "TimelineView|Timeline\.tsx" to verify all touched
# Agent F (Instruments): rg "Instruments|Piano|Drum|Chord" to verify scope
```

---

## Phase 1: Foundation (Single Agent, Sequential)

**Goal**: Establish all shared infrastructure, patterns, and components that other agents will depend on.

**CRITICAL**: This phase MUST complete before any Phase 2 work begins. All subsequent agents will reference these foundations.

### 1.1 Tailwind Configuration

**File**: `frontend/tailwind.config.js`

**Reference**: UX_GUIDELINES.md §5 (Z-Index System), §10 (Tailwind Config Extensions)

Add the following extensions:

```javascript
module.exports = {
  theme: {
    extend: {
      // Semantic z-index scale (§5)
      zIndex: {
        'base': '0',
        'elevated': '10',
        'dropdown': '100',
        'sticky': '200',
        'fixed': '300',
        'modal-backdrop': '400',
        'modal': '500',
        'popover': '600',
        'toast': '700',
        'tooltip': '800',
      },
      // Orientation & PWA media queries (§10)
      screens: {
        'pwa': { raw: '(display-mode: standalone)' },
        'landscape': { raw: '(orientation: landscape)' },
        'portrait': { raw: '(orientation: portrait)' },
      },
      // Viewport height utilities (§6)
      height: {
        'dvh': '100dvh',
        'svh': '100svh',
        'screen-safe': 'calc(100dvh - env(safe-area-inset-top) - env(safe-area-inset-bottom))',
      },
      // Safe area spacing (§3)
      spacing: {
        'safe-top': 'env(safe-area-inset-top)',
        'safe-bottom': 'env(safe-area-inset-bottom)',
        'safe-left': 'env(safe-area-inset-left)',
        'safe-right': 'env(safe-area-inset-right)',
      },
    }
  },
  plugins: [
    require('@tailwindcss/container-queries'),
  ],
}
```

**Verification**: Run `npm run build` to confirm no config errors.

---

### 1.2 CSS Foundation Updates

**File**: `frontend/src/index.css`

**Reference**: UX_GUIDELINES.md §3 (Safe Area Strategy), §6 (Responsive Units)

Add/update these CSS custom properties and utilities:

```css
:root {
  /* Safe area CSS custom properties with fallbacks (§3) */
  --safe-top: env(safe-area-inset-top, 0px);
  --safe-right: env(safe-area-inset-right, 0px);
  --safe-bottom: env(safe-area-inset-bottom, 0px);
  --safe-left: env(safe-area-inset-left, 0px);

  /* Chrome 135+ optimization for gesture navigation (§3) */
  --safe-max-bottom: env(safe-area-max-inset-bottom, 34px);
}

/* Dynamic viewport height with fallback */
.h-dvh {
  height: 100vh; /* Fallback */
  height: 100dvh;
}

/* Small viewport height for stable modals */
.h-svh {
  height: 100vh;
  height: 100svh;
}

/* Prevent iOS body bounce */
.overflow-hidden-ios {
  overflow: hidden;
  overscroll-behavior: none;
}

/* Container query setup for components */
.container-responsive {
  container-type: inline-size;
}
```

**Action**: Audit existing safe-area utilities and consolidate/replace with new pattern.

---

### 1.3 Viewport Meta Tag Update

**File**: `frontend/index.html`

**Reference**: UX_GUIDELINES.md §3

Update the viewport meta tag:

```html
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">
```

The `interactive-widget=resizes-content` ensures virtual keyboard resizes content rather than overlaying it.

---

### 1.4 Shared Hooks

**Directory**: `frontend/src/hooks/`

**Reference**: UX_GUIDELINES.md §7 (Footer Chrome), §8 (Header Overflow), §9 (Instruments Orientation)

#### 1.4.1 useMediaQuery Hook

**File**: `frontend/src/hooks/useMediaQuery.ts`

```typescript
import { useState, useEffect } from 'react';

export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => {
    if (typeof window === 'undefined') return false;
    return window.matchMedia(query).matches;
  });

  useEffect(() => {
    const mediaQuery = window.matchMedia(query);
    const handler = (e: MediaQueryListEvent) => setMatches(e.matches);

    mediaQuery.addEventListener('change', handler);
    return () => mediaQuery.removeEventListener('change', handler);
  }, [query]);

  return matches;
}

// Convenience exports
export const useIsLandscape = () => useMediaQuery('(orientation: landscape)');
export const useIsPortrait = () => useMediaQuery('(orientation: portrait)');
export const useIsPWA = () => useMediaQuery('(display-mode: standalone)');
```

#### 1.4.2 useContainerQuery Hook

**File**: `frontend/src/hooks/useContainerQuery.ts`

```typescript
import { useState, useEffect, RefObject } from 'react';

export function useContainerQuery(
  containerRef: RefObject<HTMLElement>,
  breakpoint: number
): boolean {
  const [isNarrow, setIsNarrow] = useState(false);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        setIsNarrow(entry.contentRect.width < breakpoint);
      }
    });

    observer.observe(container);
    return () => observer.disconnect();
  }, [containerRef, breakpoint]);

  return isNarrow;
}
```

#### 1.4.3 useScrollDirection Hook (Optional, for future auto-hide)

**File**: `frontend/src/hooks/useScrollDirection.ts`

```typescript
import { useState, useEffect, RefObject } from 'react';

type ScrollDirection = 'up' | 'down' | null;

export function useScrollDirection(scrollRef?: RefObject<HTMLElement>) {
  const [direction, setDirection] = useState<ScrollDirection>(null);
  const [isAtTop, setIsAtTop] = useState(true);

  useEffect(() => {
    const target = scrollRef?.current ?? window;
    let lastScrollY = 0;
    let ticking = false;

    const updateScrollDir = () => {
      const scrollY = scrollRef?.current?.scrollTop ?? window.scrollY;

      if (Math.abs(scrollY - lastScrollY) < 10) {
        ticking = false;
        return;
      }

      setDirection(scrollY > lastScrollY ? 'down' : 'up');
      setIsAtTop(scrollY < 10);
      lastScrollY = scrollY;
      ticking = false;
    };

    const onScroll = () => {
      if (!ticking) {
        requestAnimationFrame(updateScrollDir);
        ticking = true;
      }
    };

    target.addEventListener('scroll', onScroll, { passive: true });
    return () => target.removeEventListener('scroll', onScroll);
  }, [scrollRef]);

  return { direction, isAtTop };
}
```

**Export all hooks from**: `frontend/src/hooks/index.ts`

---

### 1.5 ViewLayout Component

**File**: `frontend/src/components/ViewLayout.tsx`

**Reference**: UX_GUIDELINES.md §2 (View Layout Template), §4 (Height Management)

This is the **most critical component**. All views will migrate to use this.

```typescript
import { ReactNode } from 'react';
import { cn } from '@/lib/utils';

interface ViewLayoutProps {
  /** View header content (ViewHeader component) */
  header?: ReactNode;
  /** View footer content (info bars, toolbars) */
  footer?: ReactNode;
  /** Main content */
  children: ReactNode;
  /** Whether main content should scroll (default: true) */
  scrollable?: boolean;
  /** Additional className for the container */
  className?: string;
  /** data-view attribute for testing/styling hooks */
  viewId?: string;
}

/**
 * Standard view layout that guarantees proper flex behavior.
 *
 * CRITICAL PATTERN: flex-1 min-h-0 on scrollable content
 * This breaks the default min-height: auto behavior that causes overflow.
 *
 * @see docs/architecture/UX_GUIDELINES.md §2, §4
 */
export function ViewLayout({
  header,
  footer,
  children,
  scrollable = true,
  className,
  viewId,
}: ViewLayoutProps) {
  return (
    <div
      className={cn('h-full flex flex-col', className)}
      data-view={viewId}
    >
      {/* View Header - fixed height, won't shrink */}
      {header && (
        <header className="shrink-0">
          {header}
        </header>
      )}

      {/* Main Content Area */}
      {/* flex-1 min-h-0 is MANDATORY - allows content to shrink below natural size */}
      <div className={cn(
        'flex-1 min-h-0',
        scrollable && 'overflow-y-auto overscroll-contain'
      )}>
        {children}
      </div>

      {/* View Footer - fixed height, won't shrink */}
      {footer && (
        <footer className="shrink-0">
          {footer}
        </footer>
      )}
    </div>
  );
}
```

**Export from**: `frontend/src/components/index.ts`

---

### 1.6 App Shell Refactor

**File**: `frontend/src/App.tsx`

**Reference**: UX_GUIDELINES.md §1 (App Shell Pattern), §7 (Footer Chrome Strategy)

Refactor the root App component to use the recommended structure:

```tsx
// Target structure (adapt to existing code)
<div className="h-dvh flex flex-col overflow-hidden">
  {/* Conditional banners - shrink-0 prevents compression */}
  {showConnectionBanner && <ConnectionBanner className="shrink-0" />}
  {showUpdateBanner && <UpdateBanner className="shrink-0" />}
  {showMemoryWarning && <MemoryWarningBar className="shrink-0" />}

  {/* Main content area - THE CRITICAL PATTERN */}
  <main className="flex-1 min-h-0 overflow-hidden">
    <ErrorBoundary>
      <CurrentViewComponent />
    </ErrorBoundary>
  </main>

  {/* Fixed footer chrome - z-fixed (300) */}
  {showRecordingActions && isRecording && (
    <RecordingActionsBar className="shrink-0 z-[310]" />
  )}
  {showTabBar && <TabBar className="shrink-0 z-fixed" />}
  {showPersistentTransport && (
    <PersistentTransport className="shrink-0 z-fixed pb-safe-bottom" />
  )}
</div>
```

**Key changes**:

1. Replace `h-screen-safe` with `h-dvh`
2. Add `overflow-hidden` to root
3. Add `shrink-0` to all chrome elements
4. Ensure `flex-1 min-h-0` on main content
5. Apply semantic z-index classes

---

### 1.7 Per-View Footer Visibility

**File**: `frontend/src/App.tsx` or new `frontend/src/hooks/useViewFooterConfig.ts`

**Reference**: UX_GUIDELINES.md §7 (Per-view footer visibility table)

Implement per-view footer configuration:

```typescript
type ViewId = 'timeline' | 'mixer' | 'clock' | 'playlist' | 'actions' | 'instruments' | 'notes';

interface FooterConfig {
  showTabBar: boolean;
  showTransport: boolean;
  transportVariant?: 'full' | 'compact';
}

const VIEW_FOOTER_CONFIG: Record<ViewId, FooterConfig> = {
  timeline:    { showTabBar: true,  showTransport: true,  transportVariant: 'full' },
  mixer:       { showTabBar: true,  showTransport: true,  transportVariant: 'full' },
  clock:       { showTabBar: false, showTransport: true,  transportVariant: 'full' },
  instruments: { showTabBar: false, showTransport: true,  transportVariant: 'compact' },
  actions:     { showTabBar: true,  showTransport: false },
  playlist:    { showTabBar: true,  showTransport: true,  transportVariant: 'full' },
  notes:       { showTabBar: true,  showTransport: true,  transportVariant: 'full' },
};

// In landscape mode, be more aggressive about hiding
const LANDSCAPE_FOOTER_CONFIG: Partial<Record<ViewId, Partial<FooterConfig>>> = {
  instruments: { showTabBar: false, showTransport: false }, // Maximum playing surface
  clock:       { showTabBar: false, showTransport: false }, // Immersive
};
```

**Integration**: Merge this with existing user preference toggles (burger menu settings).

---

### 1.8 Z-Index Audit

**Reference**: UX_GUIDELINES.md §5 (Layer assignments table)

Audit and update z-index values across the codebase:

| Component | Current | Target | File |
|-----------|---------|--------|------|
| TabBar | ? | z-fixed (300) | components/TabBar.tsx |
| PersistentTransport | ? | z-fixed (300) | components/PersistentTransport.tsx |
| RecordingActionsBar | ? | z-[310] | components/RecordingActionsBar.tsx |
| Modal/BottomSheet | z-50 | z-modal (500) | components/Modal/*.tsx |
| Color pickers | z-50 | z-popover (600) | various |
| Toasts | ? | z-toast (700) | if exists |
| ViewHeader sticky | ? | z-sticky (200) | components/ViewHeader.tsx |

**Action**: Search for all `z-` classes and update to semantic scale.

---

### 1.9 OrientationHint Component

**File**: `frontend/src/components/OrientationHint.tsx`

**Reference**: UX_GUIDELINES.md §9 (Instruments Orientation Strategy)

Create the dismissible orientation hint banner:

```typescript
import { useState } from 'react';
import { X, RotateCcw } from 'lucide-react';
import { cn } from '@/lib/utils';

interface OrientationHintProps {
  preferred: 'landscape' | 'portrait';
  className?: string;
}

export function OrientationHint({ preferred, className }: OrientationHintProps) {
  const [dismissed, setDismissed] = useState(false);

  if (dismissed) return null;

  const message = preferred === 'landscape'
    ? 'Rotate to landscape for the best experience'
    : 'Rotate to portrait for the best experience';

  return (
    <div className={cn(
      'flex items-center justify-between gap-2 px-3 py-2',
      'bg-bg-surface/90 backdrop-blur-sm rounded-lg border border-border-subtle',
      'text-sm text-text-secondary',
      className
    )}>
      <div className="flex items-center gap-2">
        <RotateCcw className="w-4 h-4" />
        <span>{message}</span>
      </div>
      <button
        onClick={() => setDismissed(true)}
        className="p-1 hover:bg-bg-hover rounded"
        aria-label="Dismiss"
      >
        <X className="w-4 h-4" />
      </button>
    </div>
  );
}
```

---

### 1.10 Phase 1 Verification Checklist

Before proceeding to Phase 2, verify:

- [ ] `npm run build` succeeds with no errors
- [ ] `npm run test` passes (if tests exist)
- [ ] Tailwind config has all new extensions
- [ ] CSS variables for safe areas are defined
- [ ] Viewport meta tag is updated
- [ ] All hooks are exported from hooks/index.ts
- [ ] ViewLayout component is exported from components/index.ts
- [ ] App.tsx uses new shell structure
- [ ] Z-index audit is complete (document any deferred items)
- [ ] OrientationHint component is ready

**Commit**: Create a single commit with message:

```
feat(layout): establish responsive architecture foundation

- Add semantic z-index scale to Tailwind config
- Add orientation/PWA media query screens
- Add safe area CSS custom properties
- Create ViewLayout component for consistent view structure
- Create responsive hooks (useMediaQuery, useContainerQuery, useScrollDirection)
- Refactor App shell to use proper flex pattern (flex-1 min-h-0)
- Add per-view footer visibility configuration
- Create OrientationHint component for soft orientation prompts

This establishes the foundation for Phase 2 view migrations.

See: docs/architecture/UX_GUIDELINES.md
```

---

## Phase 2: View Migrations (Parallel Agents)

**Prerequisites**: Phase 1 complete and committed.

Each agent works in a **separate git worktree** on a dedicated branch. All agents reference UX_GUIDELINES.md and use the ViewLayout component established in Phase 1.

### Agent Assignment Overview

| Agent | Scope | Branch | Complexity |
|-------|-------|--------|------------|
| Agent A | Timeline View | `refactor/timeline-responsive` | Medium |
| Agent B | Mixer View | `refactor/mixer-responsive` | Medium |
| Agent C | Clock View | `refactor/clock-responsive` | Low |
| Agent D | Playlist + Notes Views | `refactor/playlist-notes-responsive` | Low |
| Agent E | Actions View | `refactor/actions-responsive` | Low |
| Agent F | Instruments View | `refactor/instruments-responsive` | **High** |
| Agent G | Header Overflow Pattern | `refactor/header-overflow` | Medium |

---

### Agent A: Timeline View (HIGHEST COMPLEXITY)

**Branch**: `refactor/timeline-responsive`

**Reference**: UX_GUIDELINES.md §2, §4 | Production Checklist §1, §5, §6, §8

**⚠️ CRITICAL**: The Timeline is the most complex view in the app. It has multiple interactive layers (waveforms, regions, markers, items, playhead), gesture handling, real-time updates, and complex conditional rendering. **Take extra care with exploration and verification.**

---

#### A.0 Mandatory Exploration Phase (EXTENSIVE - DO NOT SKIP)

**Phase A.0.1: Read ALL Timeline-related files**

Read these files **completely** before writing any code. Understand how they interconnect.

**Core View:**

- `frontend/src/views/timeline/TimelineView.tsx` - Main view orchestration

**Timeline Canvas Components:**

- `frontend/src/components/Timeline/Timeline.tsx` - Main canvas
- `frontend/src/components/Timeline/MultiTrackLanes.tsx` - Track lane rendering
- `frontend/src/components/Timeline/TimelinePlayhead.tsx` - Playhead + drag
- `frontend/src/components/Timeline/TimelineRegions.tsx` - Region blocks
- `frontend/src/components/Timeline/TimelineMarkers.tsx` - Marker rendering
- `frontend/src/components/Timeline/TimelineItems.tsx` - Item rendering
- `frontend/src/components/Timeline/TimelineGrid.tsx` - Background grid
- `frontend/src/components/Timeline/TimeRuler.tsx` - Time ruler

**Info Bars (conditional rendering - only one at a time):**

- `frontend/src/components/Timeline/RegionInfoBar.tsx`
- `frontend/src/components/Timeline/RegionEditActionBar.tsx`
- `frontend/src/components/Timeline/NavigateItemInfoBar.tsx`
- `frontend/src/components/Markers/MarkerInfoBar.tsx`

**Footer Components:**

- `frontend/src/components/Toolbar/Toolbar.tsx`
- `frontend/src/components/Toolbar/ToolbarButton.tsx`
- `frontend/src/components/TrackFilter.tsx`
- `frontend/src/components/BankNavigator.tsx`

**Hooks to understand:**

- `frontend/src/components/Timeline/hooks/usePlayheadDrag.ts`
- `frontend/src/components/Timeline/hooks/useTimelineGestures.ts` (if exists)
- `frontend/src/hooks/useViewport.ts`

---

**Phase A.0.2: Discovery Grep Commands**

Run ALL of these and document the output:

```bash
# === FILE DISCOVERY ===

# Find ALL Timeline-related files (may reveal files not listed above)
rg "Timeline|timeline" --type tsx --type ts frontend/src/ -l | sort | uniq

# Find all imports of Timeline components
rg "from.*Timeline" --type tsx frontend/src/ | sort | uniq

# === LAYOUT PATTERNS ===

# Current flex structure (understand the chain)
rg "flex-col|flex-row" frontend/src/views/timeline/TimelineView.tsx -n

# Find flex-1 usage (some may be missing min-h-0)
rg "flex-1" frontend/src/views/timeline/ frontend/src/components/Timeline/ -n

# Find min-h-0 usage (compare with flex-1 results)
rg "min-h-0" frontend/src/views/timeline/ frontend/src/components/Timeline/ -n

# Find explicit heights that may cause issues
rg "h-\[\d+px\]|h-\[\d+\]|height:" frontend/src/views/timeline/ frontend/src/components/Timeline/ -n

# Find shrink-0 usage (chrome elements need this)
rg "shrink-0|flex-shrink" frontend/src/views/timeline/ frontend/src/components/Timeline/ -n

# === POSITIONING ===

# Find absolute positioning (potential overlap sources)
rg "absolute" frontend/src/views/timeline/ frontend/src/components/Timeline/ -n -B1 -A1

# Find relative positioning (stacking context creation)
rg "relative" frontend/src/views/timeline/ frontend/src/components/Timeline/ -n

# Find z-index usage (need semantic replacement)
rg "z-\[?\d+\]?|z-[a-z]+" frontend/src/views/timeline/ frontend/src/components/Timeline/ -n

# === OVERFLOW ===

# Find overflow handling
rg "overflow" frontend/src/views/timeline/ frontend/src/components/Timeline/ -n

# Find scroll containers
rg "scroll|overflow-auto|overflow-y-auto|overflow-x-auto" frontend/src/views/timeline/ frontend/src/components/Timeline/ -n

# === TOUCH GESTURES (Production Checklist §5) ===

# Find pointer event handlers
rg "onPointer" frontend/src/components/Timeline/ -n

# Find touch event handlers
rg "onTouch" frontend/src/components/Timeline/ -n

# Find elements with pointer handlers but no touch-action
rg "onPointerDown" frontend/src/components/Timeline/ -l | xargs rg -L "touch-action"

# Find pointer capture usage (critical for drag)
rg "setPointerCapture|releasePointerCapture" frontend/src/components/Timeline/ -n

# === MEMORY & PERFORMANCE (Production Checklist §1, §8) ===

# Find RAF usage
rg "requestAnimationFrame" frontend/src/components/Timeline/ frontend/src/views/timeline/ -n

# Find timer refs
rg "setTimeout|setInterval|useRef.*Timeout" frontend/src/components/Timeline/ -n

# Find ResizeObserver usage
rg "ResizeObserver" frontend/src/components/Timeline/ frontend/src/views/timeline/ -n

# Find useEffect hooks (check for cleanup)
rg "useEffect" frontend/src/components/Timeline/ frontend/src/views/timeline/ -l

# === CONDITIONAL RENDERING ===

# Find info bar conditional logic
rg "RegionInfoBar|MarkerInfoBar|NavigateItemInfoBar|RegionEditActionBar" frontend/src/views/timeline/TimelineView.tsx -n -B2 -A2

# Find toolbar conditional logic
rg "Toolbar|toolbarCollapsed" frontend/src/views/timeline/TimelineView.tsx -n
```

---

**Phase A.0.3: Document Your Findings**

Create a written summary (in your scratchpad or as comments) answering:

1. **Flex Chain Analysis**: Draw the current flex chain from TimelineView root to the scrollable content. Where does min-h-0 exist? Where is it missing?

2. **Overlap Root Cause**: What specifically causes the toolbar to overlap info bars? Is it:
   - Missing min-h-0 somewhere in the chain?
   - Absolute positioning without proper containment?
   - Z-index issues?
   - Missing shrink-0 on footer?

3. **Height Constraints**: What elements have fixed heights? Are any problematic?

4. **Stacking Contexts**: Which elements create stacking contexts (position: relative/absolute + z-index)?

5. **Touch Gesture Safety**: Do all draggable elements have proper touch-action CSS?

6. **Memory/Performance**: Are there any RAF loops, timers, or ResizeObservers that lack cleanup?

**DO NOT PROCEED TO IMPLEMENTATION UNTIL YOU CAN ANSWER ALL 6 QUESTIONS.**

---

#### A.1 Staged Implementation

**⚠️ DO NOT refactor everything at once. Use staged commits.**

**Stage 1: ViewLayout Adoption (minimal changes)**

Only change TimelineView.tsx to adopt ViewLayout wrapper:

```tsx
import { ViewLayout } from '@/components/ViewLayout';

export function TimelineView() {
  return (
    <ViewLayout
      viewId="timeline"
      header={/* existing header */}
      footer={/* existing footer */}
    >
      {/* existing content - NO CHANGES YET */}
    </ViewLayout>
  );
}
```

**After Stage 1:**

- `git diff` - Review changes are minimal
- Test in iOS Safari browser mode
- Verify no regressions

**Stage 2: Fix Flex Chain**

Add min-h-0 where identified in exploration:

```bash
# Verify your changes with diff
git diff frontend/src/views/timeline/TimelineView.tsx
```

**After Stage 2:**

- Test toolbar overlap is fixed
- Test scrolling works correctly
- Test all info bars display properly

**Stage 3: Z-Index Migration**

Replace hardcoded z-index values with semantic classes:

```bash
# Before: Find all hardcoded z-index
rg "z-\[\d+\]" frontend/src/views/timeline/ frontend/src/components/Timeline/

# After: Should return nothing
rg "z-\[\d+\]" frontend/src/views/timeline/ frontend/src/components/Timeline/
```

**Stage 4: Touch Gesture Verification**

Ensure all interactive elements have proper touch-action:

```bash
# Find elements needing touch-action
rg "onPointerDown" frontend/src/components/Timeline/ -l | xargs rg -L "touch-action"
```

---

#### A.2 Diff Review Requirements

**Before every commit, run:**

```bash
# Show staged changes
git diff --staged

# Show changes to Timeline files specifically
git diff frontend/src/views/timeline/ frontend/src/components/Timeline/
```

**Review checklist for each diff:**

- [ ] Only intended files are modified
- [ ] No accidental deletions
- [ ] No unrelated changes snuck in
- [ ] Comments and formatting are preserved
- [ ] Imports are correct
- [ ] TypeScript types are maintained

---

#### A.3 Verification Commands

**After completing all stages, run:**

```bash
# Build must pass
npm run build

# No hardcoded z-index remaining
rg "z-\[\d+\]" frontend/src/views/timeline/ frontend/src/components/Timeline/
# Expected: no results

# flex-1 always paired with min-h-0 where needed
rg "flex-1" frontend/src/views/timeline/TimelineView.tsx -B1 -A1

# ViewLayout is imported and used
rg "ViewLayout" frontend/src/views/timeline/TimelineView.tsx
# Expected: import and usage

# shrink-0 on footer elements
rg "shrink-0" frontend/src/views/timeline/TimelineView.tsx

# No touch handlers without touch-action
rg "onPointerDown" frontend/src/components/Timeline/ -l | xargs rg -L "touch-action"
# Expected: no results (all have touch-action)
```

---

#### A.4 Testing Protocol

**Manual testing required:**

1. **iOS Safari Browser Mode** (not PWA):
   - Open Timeline view
   - Select a region → RegionInfoBar appears
   - Verify toolbar does NOT overlap info bar
   - Scroll content if needed
   - Test with viewport constrained (browser chrome visible)

2. **PWA Mode**:
   - Same tests as above
   - Verify safe areas work

3. **Orientation**:
   - Test portrait and landscape
   - Verify no layout breaking

4. **Gestures**:
   - Drag playhead - works smoothly
   - Pinch zoom - works without browser hijacking
   - Scroll tracks - works without gesture conflicts

5. **Footer Interaction**:
   - Expand/collapse toolbar
   - Use TrackFilter
   - Use BankNavigator
   - Verify footer doesn't overlap content in any state

---

#### A.5 Tasks Summary

1. **Adopt ViewLayout**:

   ```tsx
   import { ViewLayout } from '@/components/ViewLayout';

   export function TimelineView() {
     return (
       <ViewLayout
         viewId="timeline"
         header={<ViewHeader currentView="timeline">...</ViewHeader>}
         footer={<TimelineFooter />}
       >
         {/* Timeline content */}
       </ViewLayout>
     );
   }
   ```

2. **Fix the toolbar overlap issue**:
   - Ensure main content area has `flex-1 min-h-0`
   - Info bars (RegionInfoBar, MarkerInfoBar, ItemInfoBar) should be inside the scrollable area OR have explicit max-height
   - Footer (Toolbar, TrackFilter, BankNavigator) uses `shrink-0`

3. **Verify nested flex chains**:
   - Every flex column between root and scrollable content needs `min-h-0`
   - Timeline canvas (200px) should be `shrink-0` or have `min-h-[200px]`

4. **Apply z-index**:
   - Toolbar: no special z-index needed (in normal flow)
   - Any absolute positioned elements: use semantic scale

**Verification**:

- Test in iOS Safari browser mode (not PWA) with multiple info bars
- Verify no overlap when viewport is constrained
- Test toolbar collapse/expand

---

### Agent B: Mixer View

**Branch**: `refactor/mixer-responsive`

**Reference**: UX_GUIDELINES.md §2, §4 | Production Checklist §3, §8

---

#### B.0 Mandatory Exploration Phase (DO THIS FIRST)

**Read these files completely before writing any code:**

- `frontend/src/views/mixer/MixerView.tsx`
- `frontend/src/components/Mixer/MixerStrips.tsx`
- `frontend/src/components/Mixer/ChannelStrip.tsx`
- `frontend/src/hooks/useResponsiveChannelCount.ts`

**Discovery grep commands:**

```bash
# Find all Mixer-related components
rg "Mixer|ChannelStrip" --type tsx frontend/src/ -l

# Check current flex patterns
rg "flex-col|flex-1|min-h-0" frontend/src/views/mixer/ frontend/src/components/Mixer/

# Find ResizeObserver usage (verify debouncing per Production Checklist §8)
rg "ResizeObserver" frontend/src/hooks/useResponsiveChannelCount.ts -A10

# Check for meter update patterns (Production Checklist §8)
rg "meter|peak" frontend/src/components/Mixer/ --type tsx

# Find z-index usage
rg "z-\[?\d+\]?" frontend/src/views/mixer/ frontend/src/components/Mixer/

# Find height handling
rg "h-\[|h-full|min-h-|max-h-" frontend/src/views/mixer/ frontend/src/components/Mixer/
```

**Document findings before proceeding:**

- How channel strips fill available height
- How useResponsiveChannelCount debounces (if at all)
- Meter update performance patterns
- Current flex chain structure

---

#### B.1 Tasks

1. **Adopt ViewLayout**:

   ```tsx
   <ViewLayout
     viewId="mixer"
     header={<ViewHeader currentView="mixer">...</ViewHeader>}
     footer={<MixerFooter />}
   >
     <MixerStrips ... />
   </ViewLayout>
   ```

2. **Ensure channel strips respect available space**:
   - MixerStrips container: `flex-1 min-h-0 overflow-hidden`
   - Individual strips should use flex to fill available height

3. **Verify useResponsiveChannelCount**:
   - Ensure it's using debounced ResizeObserver
   - Consider migrating to container query if simpler

**Verification**:

- Test channel count adapts to width
- Test vertical scrolling works when many channels
- Test footer (TrackFilter, BankNavigator, TrackInfoBar) doesn't overlap

---

### Agent C: Clock View

**Branch**: `refactor/clock-responsive`

**Reference**: UX_GUIDELINES.md §2, §7 | Production Checklist §8

---

#### C.0 Mandatory Exploration Phase (DO THIS FIRST)

**Read these files completely before writing any code:**

- `frontend/src/views/clock/ClockView.tsx`
- `frontend/src/views/clock/components/TransportControls.tsx`
- `frontend/src/views/clock/components/*.tsx` (all)

**Discovery grep commands:**

```bash
# Find all Clock-related components
rg "Clock" --type tsx frontend/src/ -l

# Find current layout patterns
rg "flex|grid" frontend/src/views/clock/

# Check transport animation patterns (Production Checklist §8 - 60fps)
rg "style\.|transform|opacity" frontend/src/views/clock/components/TransportControls.tsx

# Find clamp usage for responsive sizing
rg "clamp|cqmin" frontend/src/views/clock/

# Check for any RAF or animation loops
rg "requestAnimationFrame|useTransportAnimation" frontend/src/views/clock/
```

**Document findings before proceeding:**

- How clock elements are centered
- Transport control sizing mechanism
- Any 60fps animation concerns

---

#### C.1 Tasks

1. **Adopt ViewLayout**:

   ```tsx
   <ViewLayout
     viewId="clock"
     header={<ViewHeader currentView="clock">...</ViewHeader>}
     scrollable={false} // Clock is full-screen, no scroll needed
   >
     <ClockContent />
   </ViewLayout>
   ```

2. **Leverage per-view footer config**:
   - Clock should have TabBar hidden by default (immersive mode)
   - Transport visible for quick access

3. **Ensure transport controls scale properly**:
   - Verify `clamp()` usage for responsive button sizing
   - Test in both orientations

**Verification**:

- Test TabBar is hidden when entering Clock view
- Test all clock elements are visible and centered
- Test edit mode functionality preserved

---

### Agent D: Playlist + Notes Views

**Branch**: `refactor/playlist-notes-responsive`

**Reference**: UX_GUIDELINES.md §2 | Production Checklist §6

---

#### D.0 Mandatory Exploration Phase (DO THIS FIRST)

**Read these files completely before writing any code:**

- `frontend/src/views/playlist/PlaylistView.tsx`
- `frontend/src/views/notes/NotesView.tsx`

**Discovery grep commands:**

```bash
# Find all Playlist and Notes components
rg "Playlist|Notes" --type tsx frontend/src/views/ -l

# Check current flex patterns
rg "flex-col|flex-1|min-h-0" frontend/src/views/playlist/ frontend/src/views/notes/

# Find scroll handling
rg "overflow|scroll" frontend/src/views/playlist/ frontend/src/views/notes/

# Check for keyboard handling (Notes view has text input)
rg "onKey|keyboard|input|textarea" frontend/src/views/notes/

# Find any localStorage usage (Production Checklist - quota handling)
rg "localStorage" frontend/src/views/notes/
```

**Document findings before proceeding:**

- How lists scroll
- How text editor fills space
- Keyboard handling patterns

---

#### D.1 Tasks

1. **Adopt ViewLayout for both views**

2. **Playlist**: Ensure list scrolls properly with `flex-1 min-h-0`

3. **Notes**:
   - Text editor should fill available space
   - Footer controls (save/export) use `shrink-0`

**Verification**:

- Test scrolling in both views
- Test keyboard doesn't cause layout issues (thanks to `interactive-widget=resizes-content`)

---

### Agent E: Actions View

**Branch**: `refactor/actions-responsive`

**Reference**: UX_GUIDELINES.md §2, §7 | Production Checklist §5, §9

---

#### E.0 Mandatory Exploration Phase (DO THIS FIRST)

**Read these files completely before writing any code:**

- `frontend/src/views/actions/ActionsView.tsx`
- `frontend/src/components/Actions/*.tsx` (all)

**Discovery grep commands:**

```bash
# Find all Actions-related components
rg "Actions|ActionSection|ActionButton" --type tsx frontend/src/ -l

# Check grid/flex patterns
rg "grid|flex" frontend/src/views/actions/ frontend/src/components/Actions/

# Find scroll handling for sections
rg "overflow|scroll" frontend/src/views/actions/

# Check touch handling for action buttons
rg "onPointer|onClick|onTouch" frontend/src/components/Actions/

# Find any drag-drop for action editing
rg "drag|drop|sortable" frontend/src/views/actions/ frontend/src/components/Actions/

# Check for touch-action CSS
rg "touch-action" frontend/src/views/actions/ frontend/src/components/Actions/
```

**Document findings before proceeding:**

- How action sections are laid out
- Scroll behavior for many sections
- Edit mode implementation
- Touch/drag patterns (Production Checklist §5)

---

#### E.1 Tasks

1. **Adopt ViewLayout**

2. **Leverage per-view footer config**:
   - Actions view: Transport hidden (button grid is primary interaction)
   - TabBar visible for navigation

3. **Ensure action grid adapts to available space**:
   - Grid should use CSS Grid with `auto-fill` or container queries
   - Sections should scroll, not overflow

**Verification**:

- Test Transport is hidden in Actions view
- Test action sections scroll properly
- Test edit mode functionality preserved

---

### Agent F: Instruments View (HIGH COMPLEXITY)

**Branch**: `refactor/instruments-responsive`

**Reference**: UX_GUIDELINES.md §9 | Production Checklist §1, §5, §8

---

#### F.0 Mandatory Exploration Phase (DO THIS FIRST)

**This is the most complex refactor. Spend extra time understanding the codebase.**

**Read these files completely before writing any code:**

- `frontend/src/views/instruments/InstrumentsView.tsx`
- `frontend/src/components/Instruments/PianoKeyboard.tsx`
- `frontend/src/components/Instruments/PianoKey.tsx`
- `frontend/src/components/Instruments/ModWheel.tsx`
- `frontend/src/components/Instruments/PitchBendWheel.tsx`
- `frontend/src/components/Instruments/DrumPadGrid.tsx`
- `frontend/src/components/Instruments/DrumPad.tsx`
- `frontend/src/components/Instruments/Chords.tsx`
- `frontend/src/components/Instruments/ChordColumn.tsx`

**Discovery grep commands:**

```bash
# Find all Instrument-related components
rg "Instrument|Piano|Drum|Chord|ModWheel|PitchBend" --type tsx frontend/src/ -l

# Find current orientation handling (the hard blocks to remove)
rg "isPortrait|isLandscape|orientation|rotate" frontend/src/views/instruments/ frontend/src/components/Instruments/

# Find touch handling patterns (CRITICAL - Production Checklist §5)
rg "onPointer|onTouch|pointer.*capture" frontend/src/components/Instruments/

# Check for touch-action CSS
rg "touch-action" frontend/src/components/Instruments/

# Find timer refs for debouncing (Production Checklist §1 - memory)
rg "useRef.*setTimeout|setTimeout" frontend/src/components/Instruments/

# Find RAF usage for pitch bend / mod wheel (Production Checklist §8)
rg "requestAnimationFrame|setInterval" frontend/src/components/Instruments/

# Check MIDI output patterns
rg "sendNote|noteOn|noteOff|cc|pitchBend" frontend/src/components/Instruments/

# Find multi-touch tracking
rg "pointerId|pointer.*Map|touch.*Map" frontend/src/components/Instruments/

# Find current layout constraints
rg "h-full|w-full|flex|grid" frontend/src/components/Instruments/
```

**Document findings before proceeding:**

- How each instrument handles touch (single vs multi-touch)
- Timer/RAF cleanup patterns (or lack thereof)
- Current orientation detection mechanism
- MIDI message flow
- Layout structure for each instrument
- Memory leak risks in gesture handling

---

#### F.1 Tasks

#### F.1 Remove Hard Orientation Blocks

Replace the current "rotate to X orientation" blocking screens with:

1. Soft `OrientationHint` banner (dismissible)
2. Functional layouts for BOTH orientations

#### F.2 Piano Keyboard - Portrait Layout

**Current**: Only works in landscape (2+ octaves horizontal)

**New Portrait Layout**:

- Show 2 octaves with horizontal scroll
- Octave shift buttons more prominent
- Keys may be slightly narrower but still playable (min 44px touch target)

```tsx
function PianoKeyboard({ layout }: { layout: 'portrait' | 'landscape' }) {
  if (layout === 'portrait') {
    return (
      <div className="h-full flex flex-col">
        <div className="shrink-0 flex justify-center gap-2 py-2">
          {/* Octave selector - more prominent in portrait */}
          <OctaveSelector size="lg" />
        </div>
        <div className="flex-1 min-h-0 overflow-x-auto overscroll-contain">
          {/* Horizontal scrolling keyboard */}
          <div className="h-full flex" style={{ width: `${octaveCount * octaveWidth}px` }}>
            {/* Render keys */}
          </div>
        </div>
      </div>
    );
  }

  // Existing landscape layout
  return (/* ... */);
}
```

#### F.3 Drum Pads - Landscape Layout

**Current**: Only works in portrait (4×4 grid)

**New Landscape Layout**:

- Maintain 4×4 grid
- Add side panel(s) for additional controls (velocity, channel, etc.)

```tsx
function DrumPadGrid({ layout }: { layout: 'portrait' | 'landscape' }) {
  if (layout === 'landscape') {
    return (
      <div className="h-full flex gap-2">
        {/* Optional left panel */}
        <div className="shrink-0 w-16 flex flex-col justify-center gap-2">
          <ChannelSelector compact />
        </div>

        {/* 4×4 grid - constrained to square aspect */}
        <div className="flex-1 flex items-center justify-center">
          <div className="aspect-square max-h-full max-w-full grid grid-cols-4 gap-0.5">
            {/* Drum pads */}
          </div>
        </div>

        {/* Optional right panel */}
        <div className="shrink-0 w-16 flex flex-col justify-center gap-2">
          <VelocitySlider />
        </div>
      </div>
    );
  }

  // Existing portrait layout
  return (/* ... */);
}
```

#### F.4 Chord Pads - Portrait Layout

**Current**: Only works in landscape (7 horizontal columns)

**New Portrait Layout**:

- Stack columns vertically OR
- Show fewer columns with horizontal scroll OR
- Show 2-row layout (I-III-V / ii-IV-vi-vii°)

Recommended: **Horizontal scroll with snap**

```tsx
function ChordPads({ layout }: { layout: 'portrait' | 'landscape' }) {
  if (layout === 'portrait') {
    return (
      <div className="h-full flex flex-col">
        {/* Header with settings - collapse to overflow menu */}
        <div className="shrink-0">
          <ChordSettingsHeader compact />
        </div>

        {/* Horizontally scrolling chord columns */}
        <div className="flex-1 min-h-0 overflow-x-auto snap-x snap-mandatory">
          <div className="h-full flex gap-2 px-2" style={{ width: `${7 * columnWidth}px` }}>
            {CHORD_DEGREES.map(degree => (
              <ChordColumn
                key={degree}
                degree={degree}
                className="snap-center"
                style={{ width: columnWidth }}
              />
            ))}
          </div>
        </div>
      </div>
    );
  }

  // Existing landscape layout
  return (/* ... */);
}
```

#### F.5 InstrumentsView Integration

```tsx
import { useIsLandscape } from '@/hooks';
import { OrientationHint } from '@/components/OrientationHint';
import { ViewLayout } from '@/components/ViewLayout';

const INSTRUMENT_PREFERENCES = {
  drums: 'portrait',
  piano: 'landscape',
  chords: 'landscape',
} as const;

export function InstrumentsView() {
  const isLandscape = useIsLandscape();
  const layout = isLandscape ? 'landscape' : 'portrait';

  const showHint =
    (instrument === 'piano' || instrument === 'chords') && !isLandscape ||
    instrument === 'drums' && isLandscape;

  return (
    <ViewLayout
      viewId="instruments"
      header={<InstrumentsHeader />}
      scrollable={false}
    >
      <div className="h-full relative">
        {showHint && (
          <OrientationHint
            preferred={INSTRUMENT_PREFERENCES[instrument]}
            className="absolute top-2 inset-x-4 z-elevated"
          />
        )}

        {instrument === 'drums' && <DrumPadGrid layout={layout} />}
        {instrument === 'piano' && <PianoKeyboard layout={layout} />}
        {instrument === 'chords' && <ChordPads layout={layout} />}
      </div>
    </ViewLayout>
  );
}
```

#### F.6 Per-View Footer for Instruments

- TabBar: **Hidden** (need maximum playing surface)
- Transport: **Compact variant** or **hidden** in landscape

Consider a floating mini-transport button that expands on tap.

**Verification**:

- Test ALL instruments in BOTH orientations
- Verify no hard blocks remain
- Verify orientation hint is dismissible
- Verify touch targets are ≥44px
- Test MIDI output works in both orientations

---

### Agent G: Header Overflow Pattern

**Branch**: `refactor/header-overflow`

**Reference**: UX_GUIDELINES.md §8 | Production Checklist §5

---

#### G.0 Mandatory Exploration Phase (DO THIS FIRST)

**Read these files completely before writing any code:**

- `frontend/src/components/ViewHeader.tsx`
- `frontend/src/components/SettingsMenu.tsx`
- `frontend/src/components/Modal/BottomSheet.tsx`
- All views that use ViewHeader (to understand current children patterns)

**Discovery grep commands:**

```bash
# Find ViewHeader usage across all views
rg "ViewHeader" --type tsx frontend/src/views/ -A5

# Find current header children patterns
rg "<ViewHeader" --type tsx frontend/src/ -A10

# Check what controls are passed to headers
rg "currentView=" --type tsx frontend/src/views/

# Find existing overflow/menu patterns
rg "OverflowMenu|MoreVertical|kebab" --type tsx frontend/src/

# Check BottomSheet implementation for reuse
rg "BottomSheet" --type tsx frontend/src/components/Modal/

# Find views with many header controls (candidates for overflow)
rg "ViewHeader" frontend/src/views/instruments/ -A15

# Check touch targets on header controls (Production Checklist §5)
rg "w-\d|h-\d|p-\d" frontend/src/components/ViewHeader.tsx
```

**Document findings before proceeding:**

- Current ViewHeader prop interface
- Which views have crowded headers
- BottomSheet API for reuse
- Touch target sizes in headers

---

#### G.1 Tasks

#### G.1 Create OverflowMenu Component

```tsx
import { MoreVertical } from 'lucide-react';
import { BottomSheet } from '@/components/Modal/BottomSheet';

interface OverflowMenuItem {
  id: string;
  label: string;
  icon?: React.ReactNode;
  onSelect: () => void;
}

interface OverflowMenuProps {
  items: OverflowMenuItem[];
}

export function OverflowMenu({ items }: OverflowMenuProps) {
  const [open, setOpen] = useState(false);

  if (items.length === 0) return null;

  return (
    <>
      <button
        onClick={() => setOpen(true)}
        className="p-2 rounded hover:bg-bg-hover"
        aria-label="More options"
      >
        <MoreVertical className="w-5 h-5" />
      </button>

      <BottomSheet open={open} onClose={() => setOpen(false)}>
        <div className="flex flex-col">
          {items.map(item => (
            <button
              key={item.id}
              onClick={() => {
                item.onSelect();
                setOpen(false);
              }}
              className="flex items-center gap-3 px-4 py-3 hover:bg-bg-hover"
            >
              {item.icon}
              <span>{item.label}</span>
            </button>
          ))}
        </div>
      </BottomSheet>
    </>
  );
}
```

#### G.2 Update ViewHeader for Progressive Disclosure

```tsx
interface ViewHeaderProps {
  currentView: ViewId;
  children?: ReactNode;
  // New props for overflow pattern
  primaryActions?: ReactNode;
  overflowItems?: OverflowMenuItem[];
}

export function ViewHeader({
  currentView,
  children,
  primaryActions,
  overflowItems = [],
}: ViewHeaderProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const isNarrow = useContainerQuery(containerRef, 400);

  return (
    <header
      ref={containerRef}
      className="flex items-center justify-between px-3 py-2 container-responsive"
    >
      <SettingsMenu currentView={currentView} />

      <div className="flex-1 flex items-center justify-end gap-2">
        {/* Children (view-specific controls) */}
        {!isNarrow && children}

        {/* Primary actions always visible */}
        {primaryActions}

        {/* Overflow menu */}
        <OverflowMenu items={[
          ...(isNarrow && children ? childrenAsOverflowItems : []),
          ...overflowItems,
        ]} />
      </div>

      <ConnectionStatus />
    </header>
  );
}
```

#### G.3 Apply to Chord Pads Header

The Chord Pads header has: Key, Scale, Octave, Gear menu

**Priority** (last to collapse → first to collapse):

1. Gear menu (always visible as overflow trigger)
2. Key selector (most frequently changed)
3. Scale selector
4. Octave selector (least frequently changed)

```tsx
// In InstrumentsView for Chords
<ViewHeader
  currentView="instruments"
  primaryActions={<GearMenu />}
>
  {/* These collapse to overflow on narrow viewports */}
  <KeySelector />
  <ScaleSelector />
  <OctaveSelector />
</ViewHeader>
```

**Verification**:

- Test header in narrow viewport (portrait phone)
- Verify controls collapse to overflow menu
- Verify overflow menu opens as bottom sheet
- Test all overflow items are functional

---

## Phase 3: Integration & Testing

**Prerequisites**: All Phase 2 branches merged.

**Tasks**:

1. **Cross-view navigation testing**:
   - Verify footer visibility changes correctly per view
   - Verify no layout flash when switching views

2. **Orientation change testing**:
   - Test rotation while on each view
   - Verify no content jump or flash

3. **PWA vs Browser testing**:
   - Test in Safari browser mode
   - Test in PWA (installed) mode
   - Verify layouts work in both

4. **Android testing** (if device available):
   - Test safe areas on Android Chrome
   - Test PWA installation and behavior

5. **Performance audit**:
   - Check for layout thrashing
   - Verify ResizeObservers are debounced
   - Run Lighthouse mobile audit

---

## Epilogue: Documentation Consolidation

**After all phases complete**:

1. **Archive the research query** (`majestic-munching-alpaca.md`) - it served its purpose

2. **Update DEVELOPMENT.md** with:
   - Link to UX_GUIDELINES.md
   - Summary of responsive patterns to follow
   - "When creating a new view, use ViewLayout" guidance

3. **Update UX_GUIDELINES.md**:
   - Add "Implementation Status" section marking all items complete
   - Add any lessons learned during implementation
   - Add any new patterns discovered

4. **Consider renaming** `docs/architecture/UX_GUIDELINES.md` to `RESPONSIVE_ARCHITECTURE.md` or keeping as-is

5. **Final commit**:

   ```
   docs: consolidate responsive architecture documentation

   - Update DEVELOPMENT.md with responsive patterns summary
   - Mark UX_GUIDELINES.md implementation complete
   - Archive planning documents
   ```

---

## Quick Reference: Agent Checklist

### Before Writing Any Code

- [ ] Read UX_GUIDELINES.md sections relevant to your scope
- [ ] Read FRONTEND_PRODUCTION_REVIEW_CHECKLIST.md sections relevant to your scope
- [ ] Complete **Mandatory Exploration Phase** (section X.0) for your agent
- [ ] Run all discovery grep commands and document findings
- [ ] Identify all files in your scope (don't miss edge cases)
- [ ] Note any surprises or deviations from expected patterns

### During Implementation

- [ ] Use `ViewLayout` component for view structure
- [ ] Apply `flex-1 min-h-0` pattern for scrollable content
- [ ] Use semantic z-index classes from Tailwind config
- [ ] Use `useMediaQuery`/`useIsLandscape` for orientation detection
- [ ] Ensure all hooks have proper cleanup (Production Checklist §1)
- [ ] Verify touch-action on interactive elements (Production Checklist §5)
- [ ] No layout-thrashing animations (Production Checklist §8)

### Before Committing

- [ ] Run `npm run build` - no TypeScript errors
- [ ] Run `npm run test` - tests pass
- [ ] Run verification grep to confirm all items addressed:

```bash
# Verify no remaining hardcoded z-index in your scope
rg "z-\[\d+\]" frontend/src/[YOUR_SCOPE]/

# Verify flex-1 has min-h-0 where needed
rg "flex-1" frontend/src/[YOUR_SCOPE]/ -B1 -A1 | rg -v "min-h-0"

# Verify no h-screen-safe remaining (should be h-dvh)
rg "h-screen-safe" frontend/src/[YOUR_SCOPE]/

# Verify ViewLayout adopted (should see import)
rg "ViewLayout" frontend/src/[YOUR_SCOPE]/
```

### Testing Requirements

- [ ] Test in constrained viewport (iOS Safari browser mode, not PWA)
- [ ] Test both orientations if applicable
- [ ] Test view switching (footer visibility changes correctly)
- [ ] Check for visual overflow/overlap issues

### Commit Standards

- [ ] Create atomic commits with clear messages
- [ ] Reference UX_GUIDELINES.md section in commit body
- [ ] Example format:

  ```
  refactor(timeline): adopt ViewLayout and fix flex chain

  - Migrate to ViewLayout component for consistent structure
  - Add min-h-0 to main content area to enable proper scrolling
  - Apply shrink-0 to footer elements
  - Update z-index to semantic scale

  Fixes toolbar overlap issue in constrained viewports.

  See: docs/architecture/UX_GUIDELINES.md §2, §4
  ```
