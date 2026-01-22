# World-class responsive PWA architecture for REAmo

Android and iOS now both support safe area insets via `env(safe-area-inset-*)`, but **iOS blocks orientation lock entirely** while Android requires fullscreen mode—forcing a CSS-first responsive strategy rather than programmatic orientation control. The research reveals that professional music apps like KORG Gadget support both orientations with optimized layouts for each, rather than hard-blocking "wrong" orientations. For your **104px footer chrome**, UX research indicates this is acceptable in portrait (~12% of viewport) but problematic in landscape (~27%), suggesting auto-collapse behavior or per-view visibility.

---

## 1. App shell pattern: fixed chrome with flex-based content

The optimal structure uses flex-direction column with explicit `min-h-0` on the scrollable content area—this pattern is critical because flex items default to `min-height: auto`, which breaks scrolling in fixed-height containers.

```html
<!-- Recommended App Shell Structure -->
<div class="h-dvh flex flex-col overflow-hidden">
  <!-- Conditional banners (z-400) -->
  <ConnectionBanner class="shrink-0" />
  <UpdateBanner class="shrink-0" />
  <MemoryWarningBar class="shrink-0" />
  
  <!-- Main content area - THE CRITICAL PATTERN -->
  <main class="flex-1 min-h-0 overflow-hidden">
    <CurrentViewComponent class="h-full flex flex-col" />
  </main>
  
  <!-- Fixed footer chrome (z-300) -->
  <RecordingActionsBar class="shrink-0" />
  <TabBar class="shrink-0 h-12" />
  <PersistentTransport class="shrink-0 h-14 pb-[env(safe-area-inset-bottom)]" />
</div>
```

**Why flex over grid for the app shell:** Flexbox handles dynamic conditional elements (banners appearing/disappearing) more naturally. Grid excels when you need two-dimensional control, which isn't required for a vertical app shell.

**Key classes explained:**

- `h-dvh` — Dynamic viewport height, responds to iOS Safari's collapsible address bar
- `flex-1 min-h-0` — Takes remaining space AND allows children to scroll (breaks default flex behavior)
- `shrink-0` — Prevents chrome from being compressed when content overflows
- `overflow-hidden` on root — Prevents body scroll bounce on iOS

---

## 2. View layout template: proportional flex with explicit constraints

Each view component should follow a consistent internal structure that guarantees content never overlaps footer chrome:

```tsx
// ViewLayoutTemplate.tsx
interface ViewLayoutProps {
  header?: React.ReactNode;
  footer?: React.ReactNode;
  children: React.ReactNode;
  scrollable?: boolean; // default true
}

export function ViewLayout({ header, footer, children, scrollable = true }: ViewLayoutProps) {
  return (
    <div className="h-full flex flex-col">
      {/* View Header - fixed height */}
      {header && (
        <header className="shrink-0 h-14 border-b">
          {header}
        </header>
      )}
      
      {/* Main Content - flex-1 with min-h-0 is MANDATORY */}
      <div className={cn(
        "flex-1 min-h-0",
        scrollable && "overflow-y-auto overscroll-contain"
      )}>
        {children}
      </div>
      
      {/* View Footer (info bars, toolbars) */}
      {footer && (
        <footer className="shrink-0">
          {footer}
        </footer>
      )}
    </div>
  );
}
```

**Proportions guidance:** Rather than fixed percentages, use `shrink-0` for chrome and `flex-1` for content. This naturally distributes space while preventing overlap. The explicit `min-h-0` override is what makes this pattern work.

---

## 3. Safe area strategy: unified cross-platform approach

Both iOS and Android now support `env(safe-area-inset-*)` when `viewport-fit=cover` is set. The key differences are in **when** values appear and Chrome 135's new dynamic safe areas.

**Required meta viewport:**

```html
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">
```

**CSS custom properties for safe areas:**

```css
:root {
  /* Fallbacks for browsers without safe area support */
  --safe-top: env(safe-area-inset-top, 0px);
  --safe-right: env(safe-area-inset-right, 0px);
  --safe-bottom: env(safe-area-inset-bottom, 0px);
  --safe-left: env(safe-area-inset-left, 0px);
  
  /* Chrome 135+ static maximum for performance */
  --safe-max-bottom: env(safe-area-max-inset-bottom, 34px);
}
```

**Platform-specific behaviors:**

| Platform | Top Inset | Bottom Inset | Notes |
|----------|-----------|--------------|-------|
| iOS with notch | 47-59px | 34px | Dynamic Island varies by model |
| iOS without notch | 20px | 0px | Status bar height |
| Android with notch | Varies | 0-48px | Gesture nav adds bottom inset |
| Android no notch | 0px | 0px | Returns zero, not status bar |

**Chrome 135+ optimization** (prevents layout thrashing during gesture navigation):

```css
.bottom-nav {
  /* Static padding using max value */
  padding-bottom: var(--safe-max-bottom);
  /* Dynamic positioning adjustment */
  bottom: calc(var(--safe-bottom) - var(--safe-max-bottom));
}
```

**⚠️ Do NOT use** `padding-bottom: env(safe-area-inset-bottom)` directly on fixed elements—Chrome detects this pattern and disables smooth gesture animations.

---

## 4. Height management strategy: preventing overflow without fixed proportions

The symptom of "toolbar overlapping info bars" indicates missing `min-h-0` somewhere in the flex chain. Here's the debugging checklist and solution:

**The problem:** When a flex column's child has content taller than available space, the child's `min-height: auto` (default) prevents shrinking, causing overflow.

**The solution chain:**

```html
<!-- Every flex container in the vertical chain needs this pattern -->
<div class="h-dvh flex flex-col">           <!-- Root: explicit height -->
  <header class="shrink-0">...</header>     <!-- Chrome: won't shrink -->
  <main class="flex-1 min-h-0">             <!-- Content: CAN shrink below content -->
    <div class="h-full flex flex-col">      <!-- Nested: inherit full height -->
      <div class="shrink-0">View header</div>
      <div class="flex-1 min-h-0 overflow-y-auto"> <!-- Scrollable -->
        <!-- Tall content goes here -->
      </div>
      <div class="shrink-0">Info bar</div>  <!-- Won't be overlapped -->
    </div>
  </main>
  <footer class="shrink-0">...</footer>     <!-- Chrome: won't shrink -->
</div>
```

**When vertical space is constrained (landscape phone):**

1. Main content area scrolls, not individual sections
2. View headers remain sticky within their scroll container
3. Footer chrome either auto-hides or moves to side rail
4. Never use `position: absolute` for elements that should respect layout flow

**Tailwind classes reference:**

- `shrink-0` → `flex-shrink: 0` (don't compress)
- `flex-1` → `flex: 1 1 0%` (grow to fill, can shrink)
- `min-h-0` → `min-height: 0` (allow shrinking below content)

---

## 5. Z-index system: scalable layering with CSS variables

Define a semantic z-index scale in your Tailwind config and CSS variables:

```javascript
// tailwind.config.js
module.exports = {
  theme: {
    extend: {
      zIndex: {
        'base': '0',
        'elevated': '10',
        'dropdown': '100',
        'sticky': '200',
        'fixed': '300',        // App chrome (headers, footers)
        'modal-backdrop': '400',
        'modal': '500',
        'popover': '600',
        'toast': '700',
        'tooltip': '800',
      }
    }
  }
}
```

**Layer assignments for REAmo:**

| Element | Z-Index | Rationale |
|---------|---------|-----------|
| Base view content | 0 | Normal document flow |
| Sticky view headers | z-sticky (200) | Above content, below fixed |
| TabBar | z-fixed (300) | App-level fixed chrome |
| PersistentTransport | z-fixed (300) | Same layer as TabBar |
| RecordingActionsBar | z-fixed + 10 (310) | Above other fixed chrome |
| Bottom sheets | z-modal (500) | Above all fixed chrome |
| Contextual menus | z-popover (600) | Above modals if needed |
| Toast notifications | z-toast (700) | Always visible |

**Stacking context isolation:** Use `isolation: isolate` on modal containers to create a fresh stacking context, preventing z-index conflicts with the rest of the app.

---

## 6. Responsive units recommendation

| Element Type | Recommended Unit | Rationale |
|--------------|------------------|-----------|
| App container height | `dvh` with `vh` fallback | Responds to mobile browser chrome |
| Touch targets | `px` (48px minimum) | Consistent touch experience |
| Icon sizes | `px` (20-24px) | Visual consistency |
| Typography | `rem` | Respects user accessibility |
| Spacing | `rem` or Tailwind scale | Proportional, accessible |
| Fixed chrome heights | `px` (48px, 56px) | Predictable layout |
| Container-relative sizing | `cqw`, `cqh` | Component adaptability |
| Modal max heights | `svh` | Stable, doesn't reflow |

**Critical distinction:**

- `svh` (small viewport height): Use for stable layouts—accounts for browser UI being visible
- `dvh` (dynamic viewport height): Use for the app container—adapts as Safari toolbar hides
- `lvh` (large viewport height): Use for background images only

**Example: stable modal with dynamic app:**

```css
.app { height: 100dvh; }           /* App adapts to toolbar */
.modal { max-height: 90svh; }      /* Modal stays stable */
```

**Touch targets:** Research confirms **48×48px** as the modern consensus (Material Design 3). Apple's 44pt converts to 44px at 1x but the 48px standard provides better accessibility. Use `min-h-[48px] min-w-[48px]` with padding for adequate touch areas around smaller visual icons.

---

## 7. Footer chrome strategy: research-backed recommendations

### UX research findings (with citations)

**Nielsen Norman Group** finds that navigation bars "take space on the page, and work well when the number of navigation options is small" and warns that "overall chrome may add up wasting too much space." [nngroup.com/articles/mobile-navigation-patterns]

**Steven Hoober's thumb zone research** (1,333 observations) shows 75% of phone interactions are thumb-driven, with the bottom third being the "Natural Zone"—validating bottom placement of transport controls. [uxmatters.com/mt/archives/2013/02/how-do-users-really-hold-mobile-devices.php]

**Material Design** explicitly states: "The bottom navigation bar can disappear and reappear to allow immersive content views" with scroll-to-hide behavior. [material.io/components/bottom-navigation]

### Viewport analysis

For your **104px footer** (TabBar 48px + PersistentTransport 56px):

- **iPhone 14 portrait** (844px): 104px = 12.3% ✓ Acceptable
- **iPhone 14 landscape** (390px): 104px = 26.7% ⚠️ Problematic
- **iPad landscape** (1024px): 104px = 10.2% ✓ Acceptable

### Recommended strategy

**Implement scroll-aware footer behavior:**

```tsx
// useScrollDirection hook
function useScrollDirection() {
  const [direction, setDirection] = useState<'up' | 'down' | null>(null);
  const [isAtTop, setIsAtTop] = useState(true);
  
  useEffect(() => {
    let lastScrollY = window.scrollY;
    
    const handleScroll = () => {
      const currentScrollY = window.scrollY;
      setDirection(currentScrollY > lastScrollY ? 'down' : 'up');
      setIsAtTop(currentScrollY < 10);
      lastScrollY = currentScrollY;
    };
    
    window.addEventListener('scroll', handleScroll, { passive: true });
    return () => window.removeEventListener('scroll', handleScroll);
  }, []);
  
  return { direction, isAtTop };
}
```

**Per-view footer visibility:**

| View | TabBar | Transport | Rationale |
|------|--------|-----------|-----------|
| Timeline | Visible | Visible | Core workflow needs both |
| Mixer | Visible | Visible | Same |
| Clock | Hidden | Visible | Immersive display mode |
| Instruments | Hidden | Compact | Maximum playing surface |
| Actions | Visible | Hidden | Button grid is primary |

**Landscape mode:** Auto-collapse TabBar, show only compact transport (play/stop/record in a single row) or move to side rail.

**Professional music app pattern:** GarageBand, Cubasis, and KORG Gadget all keep transport controls **persistent and always accessible**. They're typically at the **top** of the screen in DAW apps, but bottom placement works for a remote control app where thumb access to transport is primary.

---

## 8. Header controls overflow pattern

When ViewHeader has too many controls (Key, Scale, Octave, Gear) for narrow viewports:

**Recommended pattern: Progressive disclosure with overflow menu**

```tsx
function ViewHeader({ title, primaryAction, secondaryActions, menuActions }) {
  const containerRef = useRef(null);
  const isNarrow = useContainerQuery(containerRef, 400); // < 400px
  
  return (
    <header ref={containerRef} className="h-14 flex items-center justify-between px-4">
      <h1 className="text-lg font-semibold truncate">{title}</h1>
      
      <div className="flex items-center gap-2">
        {/* Primary action always visible */}
        {primaryAction}
        
        {/* Secondary actions: visible when space allows */}
        {!isNarrow && secondaryActions.map(action => (
          <ActionButton key={action.id} {...action} />
        ))}
        
        {/* Overflow menu: contains secondary actions when narrow + menu actions */}
        <OverflowMenu 
          items={[
            ...(isNarrow ? secondaryActions : []),
            ...menuActions
          ]} 
        />
      </div>
    </header>
  );
}
```

**Priority hierarchy for Chord Pads header:**

1. **Always visible:** Gear menu (single icon)
2. **First to collapse:** Octave selector (least frequently changed)
3. **Second to collapse:** Scale selector
4. **Last to collapse:** Key selector

**Alternative: Bottom sheet for complex controls**
For views with many interdependent controls (Key + Scale + Octave are related), a bottom sheet provides more space and allows showing relationships between options.

**Material Design guidance:** Keep 2-3 most critical actions visible as icons; remaining actions go in kebab (three-dot) overflow menu.

---

## 9. Instruments orientation strategy

### The API reality

**`screen.orientation.lock()` does NOT work on iOS Safari**—period. This is the single most important constraint. Android Chrome supports it but requires fullscreen mode first.

**Manifest `orientation` field:** Sets the default orientation at PWA launch but doesn't enforce runtime locking and has limited iOS support.

### Professional music app patterns

**KORG Gadget's approach** (industry best practice):
> "It gives you an ideal music production workflow based mainly on the portrait orientation... When you want to focus on specifics, you can smoothly switch to landscape orientation."

Key insight: KORG supports **both orientations with different optimized layouts**, not hard blocks.

### Recommended strategy for REAmo instruments

| Instrument | Portrait | Landscape | Strategy |
|------------|----------|-----------|----------|
| **Drum Pads** | 4×4 optimal | 4×4 with side controls | Both functional |
| **Piano** | 2 octaves, scrollable | 4+ octaves | Soft prompt for landscape |
| **Chord Pads** | Stacked/scrollable | 7 columns | Soft prompt for landscape |

**Implementation:**

```tsx
function InstrumentView({ instrument }: { instrument: InstrumentType }) {
  const isLandscape = useMediaQuery('(orientation: landscape)');
  const preferredOrientation = INSTRUMENT_PREFERENCES[instrument];
  
  const showOrientationHint = 
    preferredOrientation === 'landscape' && !isLandscape ||
    preferredOrientation === 'portrait' && isLandscape;
  
  return (
    <div className="h-full relative">
      {/* Non-blocking orientation hint */}
      {showOrientationHint && (
        <OrientationHint 
          preferred={preferredOrientation}
          dismissible
          className="absolute top-2 inset-x-4 z-10"
        />
      )}
      
      {/* Instrument renders in BOTH orientations */}
      <InstrumentRenderer 
        instrument={instrument}
        layout={isLandscape ? 'landscape' : 'portrait'}
      />
    </div>
  );
}
```

**Piano in portrait:** Show 2 octaves with an octave shift control and smooth horizontal scroll. Many users successfully play piano apps in portrait with this pattern.

**Drum pads in landscape:** Maintain 4×4 grid but add side panels for velocity, sample browser, or mixer controls—turning "wasted" horizontal space into useful functionality.

**Never hard-block content.** WCAG 1.3.4 (Orientation) requires content to work in any orientation unless "a specific display orientation is essential." A remote control app doesn't meet the "essential" bar.

---

## 10. Holistic responsive system: how everything connects

### The unified mental model

```
┌─────────────────────────────────────────────────────────────────┐
│                        VIEWPORT (100dvh)                        │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ Safe Area Top: env(safe-area-inset-top)                   │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │ Conditional Banners (shrink-0, z-400)                     │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │                                                           │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │ View Container (flex-1 min-h-0)                     │  │  │
│  │  │  ┌───────────────────────────────────────────────┐  │  │  │
│  │  │  │ View Header (shrink-0, z-sticky)              │  │  │  │
│  │  │  ├───────────────────────────────────────────────┤  │  │  │
│  │  │  │ Scrollable Content (flex-1 min-h-0 overflow)  │  │  │  │
│  │  │  │   @container for component queries            │  │  │  │
│  │  │  ├───────────────────────────────────────────────┤  │  │  │
│  │  │  │ View Footer/Info Bars (shrink-0)              │  │  │  │
│  │  │  └───────────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  │                                                           │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │ TabBar (shrink-0, 48px, z-fixed, hideable)                │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │ PersistentTransport (shrink-0, 56px, z-fixed)             │  │
│  ├───────────────────────────────────────────────────────────┤  │
│  │ Safe Area Bottom: env(safe-area-inset-bottom)             │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Responsive technique decision tree

```
Need responsive behavior?
├── Based on viewport size? → Media Query
│   └── @media (orientation: landscape), @media (min-width: 768px)
├── Based on container size? → Container Query  
│   └── @container (min-width: 400px) { ... }
├── Need JavaScript access to dimensions? → ResizeObserver (debounced)
│   └── Complex conditional rendering, performance animations
└── Based on PWA vs browser? → display-mode media query
    └── @media (display-mode: standalone) { ... }
```

### Tailwind config extensions

```javascript
// tailwind.config.js
module.exports = {
  theme: {
    extend: {
      screens: {
        'pwa': { raw: '(display-mode: standalone)' },
        'landscape': { raw: '(orientation: landscape)' },
        'portrait': { raw: '(orientation: portrait)' },
      },
      height: {
        'dvh': '100dvh',
        'svh': '100svh',
        'screen-safe': 'calc(100dvh - env(safe-area-inset-top) - env(safe-area-inset-bottom))',
      },
      spacing: {
        'safe-top': 'env(safe-area-inset-top)',
        'safe-bottom': 'env(safe-area-inset-bottom)',
        'safe-left': 'env(safe-area-inset-left)',
        'safe-right': 'env(safe-area-inset-right)',
      },
      zIndex: {
        'dropdown': '100',
        'sticky': '200',
        'fixed': '300',
        'modal-backdrop': '400',
        'modal': '500',
        'toast': '700',
      }
    }
  },
  plugins: [
    require('@tailwindcss/container-queries'),
  ],
}
```

### Anti-patterns to eliminate

| Anti-Pattern | Problem | Solution |
|--------------|---------|----------|
| `height: 100vh` | Doesn't account for mobile browser chrome | `height: 100dvh` with `100vh` fallback |
| `flex-1` without `min-h-0` | Content overflows instead of scrolling | Always pair with `min-h-0` |
| `position: absolute` for layout | Removed from flow, causes overlap | Use flexbox with `shrink-0` |
| Unconstrained z-index | Z-index wars, unpredictable layering | Semantic z-index scale |
| `padding: env(safe-area-*)` on fixed bottom elements | Chrome disables smooth gesture animations | Use `safe-area-max-inset-*` pattern |
| Many ResizeObservers without debounce | Layout thrashing, performance issues | Debounce 100-200ms, prefer CSS queries |
| Hard-blocking orientation | Accessibility violation, poor UX | Adaptive layouts with soft prompts |

### Performance checklist

- [ ] Use `contain: content` on independent card/widget components
- [ ] Debounce ResizeObserver callbacks (100-200ms)
- [ ] Animate only `transform` and `opacity` for 60fps
- [ ] Use `overscroll-behavior: contain` to prevent pull-to-refresh interference
- [ ] Set `will-change` only when animation is imminent, remove after
- [ ] Batch DOM reads before writes in any JavaScript layout code
- [ ] Use CSS container queries instead of ResizeObserver where possible

---

## Conclusion: implementation priorities

The research reveals three non-negotiable architectural decisions: **always use `flex-1 min-h-0`** on scrollable content containers to prevent overflow; **never rely on orientation lock** for iOS compatibility; and **use `100dvh`** for the app container with safe area insets applied to fixed chrome.

For immediate implementation, prioritize fixing any views with toolbar overlap by ensuring the complete flex chain has `min-h-0` at every level. Then implement the per-view footer visibility system—hiding TabBar in immersive views (Clock, Instruments) will immediately improve the landscape experience without complex auto-hide logic.

The research strongly suggests following KORG Gadget's approach for instruments: support both orientations with optimized layouts rather than blocking. A piano with 2 scrollable octaves in portrait is more useful than a "rotate your device" message, and satisfies accessibility requirements.

For the header overflow issue, the progressive disclosure pattern with a kebab overflow menu is the established solution—keep the single most-changed control visible (likely Key selector for Chord Pads) and collapse others into the menu on narrow viewports.
