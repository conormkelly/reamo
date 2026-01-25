# Responsive Design Principles for Touch-First Music Controller PWA

## What I Need

I'm building a mobile PWA (React + Tailwind) that serves as a DAW remote controller. I need **general responsive design principles** that I can document as actionable guidelines for all future frontend work—not just answers to specific component questions.

The goal: A design system document that answers "how should we approach responsive layout for touch interfaces?" with principles we can apply consistently.

## App Context

**Platform:** PWA running in Safari (iOS) and Chrome (Android). Users may run in:

- **PWA mode** (recommended): Full viewport, no browser chrome
- **Browser tab**: Safari/Chrome toolbar eats 44-90px depending on state, tabs may be visible
- Vertical space is the most constrained resource, especially on phones

**Architecture:**

```
┌─────────────────────────────┐
│ ViewHeader (44px)           │  Fixed app chrome
├─────────────────────────────┤
│ Primary Content Area        │  flex-1, dynamic height
│ (faders, timeline, piano)   │
├─────────────────────────────┤
│ SecondaryPanel (44-140px)   │  Collapsible info footer
├─────────────────────────────┤
│ TabBar (48px)               │  7 view tabs
├─────────────────────────────┤
│ PersistentTransport (56px)  │  Play/stop/record controls
└─────────────────────────────┘
+ Safe area insets (env(safe-area-inset-*))
+ Possible browser chrome (non-PWA users)
```

**Existing decisions:**

- Navigation stays visible (researched: hidden nav hurts discoverability 20%, all pro music apps keep it visible)
- Safe area CSS implemented via `env(safe-area-inset-*)`
- Using CSS `dvh` (dynamic viewport height) to handle Safari's collapsing toolbar

---

## Core Questions: General Principles

### 1. Sizing Strategy for Touch Controls

When a UI element needs to be "responsive" but also have a sensible fixed size, what's the right approach?

**Current problem:** We use percentage-based sizing (e.g., "fader height = 70% of container"). This fails because:

- 70% of 700px (tablet) = 490px → absurdly tall
- 70% of 200px (phone landscape) = 140px → wastes the remaining 30%

**What I need:** A general principle for sizing touch controls. Options I'm considering:

- **Absolute min/max with flex fill**: e.g., "min 80px, max 200px, fill available space between"
- **Size classes**: Different fixed sizes for phone/tablet contexts
- **Aspect ratio constraints**: e.g., "fader should be 4:1 height:width ratio"

**Question:** What's the established pattern for touch controls that need to scale but stay usable? Is there a formula like "min Xpx for touch, max Ypx for ergonomics, scale between"?

### 2. When to Reorganize Layout vs Scale Content

**Current problem:** On iPad portrait, we show the same layout as phone but scaled up. Faders become giant. Should we instead show a different layout (e.g., 2 rows of shorter faders)?

**Question:** What triggers a layout reorganization vs just scaling?

- Is it viewport width? Height? Aspect ratio?
- What are the breakpoints or thresholds?
- How do you decide "same layout, bigger" vs "different layout entirely"?

### 3. Persistent Chrome in Constrained Orientations

**Current problem:** Phone landscape has ~390px viewport height. Our bottom chrome (TabBar 48 + Transport 56 + SecondaryPanel 44) = 148px, leaving only 242px for content. That's 38% lost to chrome.

**Options I'm considering:**

- Move TabBar to a vertical side rail in landscape (reclaims 48px height)
- Combine transport into the side rail
- Accept the constraint and optimize content for 200-250px height

**Question:** What's the standard pattern for apps with persistent navigation when vertical space is extremely limited? Do music/creative apps move chrome to side rails in landscape? If so, what triggers the switch?

### 4. Browser vs PWA: Variable Viewport

Users in browser mode lose 44-90px to browser chrome. PWA mode gets full viewport. We can't control which they use.

**Question:** How should we design for this variability?

- Design for worst case (browser) and let PWA users have extra space?
- Detect PWA mode and adjust layout?
- What's the principle here?

### 5. Size Classes: A Unified Mental Model?

iOS uses "size classes" (compact/regular for width/height). Should web apps adopt this?

**Current approach:** Mix of `useIsLandscape()`, pixel breakpoints, and container queries. No unified system.

**Question:**

- Should we adopt a size class system? What are the right thresholds for web?
- How do size classes map to layout decisions? (e.g., "compact height → use compact strip variant")
- Is there a better mental model than size classes?

---

## Concrete Examples (for context)

These illustrate the problems, but I want **general principles**, not just answers to these specific cases.

### Example A: Mixer Faders

- Phone portrait: 80-150px faders work well
- Phone landscape: Need compact strips, but current 70% cap wastes space
- Tablet portrait: Faders scale to 400-500px, looks absurd
- Tablet landscape: ???

### Example B: Piano Keyboard

- Phone portrait: 2 octaves fills width with playable keys, but limited range
- Phone landscape: Can fit 3-4 octaves comfortably
- Pattern options: Fixed octaves + shift buttons vs horizontal scroll

### Example C: Timeline Canvas

- Needs minimum height for waveform visibility
- Region editing needs extra controls that compete for space

---

## Deliverables Requested

Please provide principles I can document as **actionable guidelines**:

1. **Touch Control Sizing Formula**
   - Minimum sizes for different control types (buttons, sliders, continuous controls)
   - Maximum sizes (when does bigger stop being better?)
   - How to scale between min/max

2. **Layout Reorganization Triggers**
   - When to use same layout scaled vs different layout
   - Breakpoint recommendations (or why breakpoints are wrong)
   - How to think about "content density" across screen sizes

3. **Chrome Positioning Strategy**
   - When bottom nav makes sense vs side rail
   - How to handle landscape on phones specifically
   - Transport controls: always visible vs on-demand?

4. **Size Class Definitions** (if recommended)
   - Thresholds for compact/regular width/height on web
   - How to map size classes to specific layout behaviors

5. **Variable Viewport Handling**
   - PWA vs browser design strategy
   - How to gracefully handle lost space

---

## Constraints

- PWA in Safari/Chrome - no native APIs
- Must support: iPhone, iPad, Android phones/tablets, all orientations
- React + Tailwind CSS (can use container queries, CSS grid, flexbox)
- Transport must remain quickly accessible (DAW remote - play/stop is critical)
- Safe area insets already implemented

## Reference Apps

These face similar challenges - how do they solve them?

- Logic Remote, GarageBand iOS (Apple's approach)
- TouchOSC, Lemur (professional control surfaces)
- Avid Control, PreSonus UC Surface (DAW remotes)
- Any other touch-first music/creative apps with good responsive design

```
