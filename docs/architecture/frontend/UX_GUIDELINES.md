# Responsive layout guidelines

Layout rules for the REAmo frontend. Code comments cite these § numbers, so keep them stable. The shipped size classes and rails are in [FRONTEND_DEVELOPMENT.md §21](../../../frontend/FRONTEND_DEVELOPMENT.md#21-dual-rail-responsive-layout-landscape-phones); the layout budget is in §19.

---

## 1. App shell pattern: fixed chrome with flex-based content

`App.tsx` (bottom-navigation mode):

```html
<div class="flex flex-col h-dvh overflow-hidden isolate ...">
  <ConnectionBanner class="shrink-0" />
  <MemoryWarningBar class="shrink-0" />
  <main class="flex-1 min-h-0 overflow-hidden">
    <ErrorBoundary><ViewComponent /></ErrorBoundary>
  </main>
  <!-- RecordingActionsBar: position fixed, z-[310], above the footer -->
  <TabBar class="shrink-0 z-fixed" />
  <PersistentTransport class="shrink-0 z-fixed safe-area-bottom" />
</div>
```

- `h-dvh` on the root: follows Safari's collapsing toolbars.
- `flex-1 min-h-0` on `<main>`: flex items default to `min-height: auto`, which stops them shrinking and breaks scrolling. `min-h-0` is what lets content scroll instead of overflowing.
- `shrink-0` on chrome so overflowing content can't compress it.
- `overflow-hidden` on the root stops iOS body bounce.
- Flex, not grid: banners appear and disappear; a vertical shell needs no second dimension.

---

## 2. View layout template: proportional flex with explicit constraints

Every view uses `components/Layout/ViewLayout.tsx` (`header`, `footer`, `children`, `scrollable`):

- header and footer `shrink-0`; content `flex-1 min-h-0`, plus `overflow-y-auto overscroll-contain` when `scrollable` (the default).
- Don't size sections with fixed percentages: `shrink-0` chrome plus `flex-1` content distributes the space and can't overlap.

---

## 3. Safe area strategy: unified cross-platform approach

Viewport meta (`frontend/index.html`):

```html
<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
```

- `viewport-fit=cover` is required, or browsers letterbox notched displays instead of exposing the insets.
- No `interactive-widget`: the on-screen keyboard overlays the page (the browser default, `resizes-visual`) instead of shrinking it. With `resizes-content`, current iOS WebKit shrinks the layout viewport for the keyboard as Android does, and WebKit hosts such as Brave can leave it shrunk after the keyboard closes, drawing the app in the top half of the screen.

Custom properties in `:root` (`index.css`): `--safe-top`, `--safe-right`, `--safe-bottom`, `--safe-left` (each `env(safe-area-inset-*, 0px)`).

Insets by platform:

| Platform | Top | Bottom | Notes |
|----------|-----|--------|-------|
| iOS with notch | 47-59px | 34px | Dynamic Island varies by model |
| iOS without notch | 20px | 0px | Status bar height |
| Android with notch | Varies | 0-48px | Gesture nav adds bottom inset |
| Android no notch | 0px | 0px | Returns zero, not status bar |

- PWA standalone mode: WebKit can return `0px` from `env()` at first, so standalone rules use a 34px fallback (`.safe-area-bottom` in `index.css`).
- Chrome 135+ on a `position: fixed` bottom element: pad with the static maximum and offset by the live inset, so Chrome keeps its smooth gesture-navigation animations. `padding-bottom: env(safe-area-inset-bottom)` directly on a fixed element makes Chrome turn them off.

  ```css
  .bottom-nav {
    padding-bottom: env(safe-area-max-inset-bottom, 34px);
    bottom: calc(var(--safe-bottom) - env(safe-area-max-inset-bottom, 34px));
  }
  ```

  Known gap: nothing uses this yet. The tab bar and transport are in flow (not fixed) and pad with `env(safe-area-inset-bottom)` via `.safe-area-bottom`; the recording actions bar is fixed and offsets by `env(safe-area-inset-bottom, 34px)`.

---

## 4. Height management strategy: preventing overflow without fixed proportions

Content overlapping an info bar or toolbar means a missing `min-h-0` somewhere in the flex chain. Every level needs it:

```html
<div class="h-dvh flex flex-col">
  <header class="shrink-0">...</header>
  <main class="flex-1 min-h-0">
    <div class="h-full flex flex-col">
      <div class="shrink-0">View header</div>
      <div class="flex-1 min-h-0 overflow-y-auto">Tall content</div>
      <div class="shrink-0">Info bar</div>
    </div>
  </main>
  <footer class="shrink-0">...</footer>
</div>
```

When vertical space is short (landscape phone):

- the content area scrolls, not individual sections;
- footer chrome moves to the side rail (§21 of the frontend guide);
- never use `position: absolute` for something that should take part in layout.

---

## 5. Z-index system: scalable layering with CSS variables

The scale is in the `@theme` block of `frontend/src/index.css` as `--z-index-*`, which Tailwind 4 turns into `z-base` … `z-tooltip`:

| Token | Value | Use |
|-------|-------|-----|
| `z-base` | 0 | Normal flow |
| `z-elevated` | 10 | Raised within a view |
| `z-dropdown` | 100 | Dropdowns |
| `z-sticky` | 200 | Sticky view headers |
| `z-fixed` | 300 | App chrome: tab bar, transport, rails |
| `z-modal-backdrop` | 400 | Dialog backdrops |
| `z-modal` | 500 | Dialogs, bottom sheets |
| `z-popover` | 600 | Contextual menus |
| `z-toast` | 700 | Toasts |
| `z-tooltip` | 800 | Tooltips |

- The recording actions bar uses `z-[310]`, just above the other fixed chrome.
- The app root has `isolation: isolate`, and dialogs, sheets, menus and toasts portal to `document.body`, outside it. So every portaled layer stacks above the app chrome whatever z-index the chrome uses, and contextual menus use `z-popover` so they open above non-modal panels (`z-modal`).

---

## 6. Responsive units recommendation

| Element | Unit | Why |
|---------|------|-----|
| App container height | `dvh` (`vh` fallback) | Follows mobile browser chrome |
| Touch targets | `px`, 44px minimum | Fingers don't scale with screens |
| Icons | `px` (20-24px) | Visual consistency |
| Typography | `rem` | Respects user text size |
| Spacing | `rem` / Tailwind scale / spacing tokens | Proportional |
| Fixed chrome heights | `px` | Predictable layout |
| Container-relative sizing | `cqw`, `cqh` | Component adaptability |
| Dialog max heights | `max-h-full` inside an `.overlay-safe-area` backdrop; `dvh` where a unit is needed | Never taller than what's visible, clear of the notch and home indicator |

- `dvh`: the app container and anything sized to the screen. `vh` is the height with Safari's toolbars hidden, so it overflows while they show; lint flags it.
- `svh`: the height with the toolbars shown. Only where something must not resize as they move.
- `lvh`: background images only.

**Dialogs:** the backdrop is `fixed inset-0`, so it already matches the visible viewport. `.overlay-safe-area` pads it by the safe-area insets (at least `--overlay-gutter`, default 1rem), and the panel takes `max-h-full` of what's left:

```tsx
<div className="fixed inset-0 flex items-center justify-center overlay-safe-area">
  <div className="max-h-full flex flex-col">…</div>
</div>
```

**Touch targets:** 44×44px minimum (`--size-touch-target-min`, Apple HIG, WCAG 2.5.5). Pad around smaller visual icons to reach it.

---

## 7. Footer chrome strategy

- Footer chrome is the tab bar plus the persistent transport. Each is a user toggle (`showTabBar`, `showPersistentTransport`); Clock fullscreen hides both.
- Landscape phones (height < 480px) move navigation and transport into the side rail instead of auto-hiding them.
- Transport stays visible in every view: recording is the primary workflow.
- Not built: per-view footer defaults (Clock hides the tab bar; Instruments shows a compact transport; Actions hides the transport; in landscape, Instruments and Clock hide both), merged with the user toggles; hiding the footer on scroll down.

---

## 8. Header controls overflow pattern

- Not built: collapsing header controls into an overflow menu (a kebab button opening a bottom sheet) on narrow headers via a container query. Priority for the chord-pad header: gear always visible; Octave collapses first, then Scale, then Key. Alternative: one bottom sheet for Key + Scale + Octave, which are related.

---

## 9. Instruments orientation strategy

- `screen.orientation.lock()` doesn't work on iOS Safari; Android needs fullscreen first. The manifest `orientation` field only sets the launch default.
- So every instrument renders in both orientations, and nothing hard-blocks or prompts. WCAG 1.3.4 (Orientation) requires content to work in any orientation unless one is essential, which a remote control isn't.
- Portrait piano: an 8-octave keyboard that scrolls horizontally; landscape: 2 octaves.
- Not built: side panels (velocity, channel) beside the drum grid in landscape.

---

## 10. Holistic responsive system: how everything connects

Which tool:

- Viewport size or orientation → media query, or `useLayoutContext` when JS needs it.
- Container size → container query (built into Tailwind 4).
- JS needs element dimensions → ResizeObserver, debounced.
- PWA vs browser → `@media (display-mode: standalone)`.

Theme tokens (colours, spacing, sizes, z-index) are in the `@theme` block of `frontend/src/index.css`; safe-area, landscape and PWA rules are plain classes in the same file. `dvh`/`svh` utilities and container queries are built into Tailwind 4.

Anti-patterns:

| Don't | Problem | Do |
|-------|---------|----|
| `height: 100vh` | Ignores mobile browser chrome | `100dvh` with `100vh` fallback |
| `flex-1` without `min-h-0` | Overflows instead of scrolling | Always pair them |
| `position: absolute` for layout | Leaves the flow, overlaps | Flex with `shrink-0` |
| Ad hoc z-index values | Unpredictable layering | The §5 scale |
| `padding: env(safe-area-*)` on fixed bottom elements | Chrome disables smooth gesture animations | The §3 `safe-area-max-inset-*` pattern |
| Many undebounced ResizeObservers | Layout thrashing | Debounce 100-200ms, prefer CSS queries |
| Hard-blocking an orientation | Accessibility violation | Layouts for both |

Performance:

- Animate only `transform` and `opacity`.
- `overscroll-behavior: contain` on scrollers, against pull-to-refresh.
- `will-change` only while an animation is imminent.
- Batch DOM reads before writes in JS layout code.
- Not done: `contain: content` on independent widgets (nothing uses it yet).
