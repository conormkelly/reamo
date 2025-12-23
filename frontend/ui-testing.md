# AI-assisted UI testing tools for React 19 + Zustand drag interactions

**Your best approach combines Playwright MCP for visual drag testing via Claude Code with Vitest for unit-level state logic verification.** The Microsoft Playwright MCP server enables Claude to launch browsers, execute coordinate-based drag sequences, and analyze screenshots. For component-level testing without browser overhead, Vitest with React Testing Library handles Zustand state mocking and pointer event simulation—though jsdom's lack of layout requires testing state changes rather than visual positions. Storybook offers a compelling middle ground with its official MCP addon, enabling Claude to inspect component stories directly.

The key constraint for your timeline drag scenario is that **jsdom-based tools cannot test actual pixel positions**, making browser-based testing via Playwright MCP essential for validating visual ripple-edit behavior. All recommended tools install as dev dependencies and won't affect your single HTML file production build.

---

## Playwright MCP server enables full browser control from Claude Code

Microsoft's official `@playwright/mcp` package (23.2k GitHub stars) provides production-ready browser automation that Claude Code can invoke directly. This is the **strongest option for visual drag testing** since it operates in a real browser with actual layout.

### Installation and configuration

```bash
# One-line installation for Claude Code
claude mcp add playwright npx @playwright/mcp@latest -- --caps=vision
```

Or configure manually in `~/.claude.json`:

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest", "--caps=vision,testing"],
      "env": {}
    }
  }
}
```

The `--caps=vision` flag enables coordinate-based pointer operations essential for drag testing.

### Drag operation capabilities

The server exposes several tools for drag interactions:

| Tool | Use case | Parameters |
|------|----------|------------|
| `browser_mouse_drag_xy` | Coordinate-based drag | `startX`, `startY`, `endX`, `endY` |
| `browser_drag` | Element-to-element drag | `startRef`, `endRef` |
| `browser_run_code` | Custom Playwright code | Raw Playwright script |
| `browser_take_screenshot` | Visual verification | `fullPage`, `element` |

For your timeline's pointer event sequences, use `browser_run_code` for granular control:

```javascript
// Claude Code would invoke this tool with:
browser_run_code({
  code: `
    const timeline = page.locator('#timeline-canvas');
    const box = await timeline.boundingBox();
    
    // Simulate drag from position 1 (100px) to position 3 (300px)
    await page.mouse.move(box.x + 100, box.y + 25);
    await page.mouse.down();
    await page.mouse.move(box.x + 300, box.y + 25, { steps: 20 });
    await page.mouse.up();
  `
})
```

### How Claude analyzes results

Claude can read element positions and Zustand state via `browser_evaluate`:

```javascript
browser_evaluate({
  function: `() => {
    const state = window.__ZUSTAND_STORE__.getState();
    return {
      regions: state.regions.map(r => ({
        id: r.id,
        position: r.startTime
      }))
    };
  }`
})
```

Screenshots return as base64 images that Claude can visually analyze for layout verification.

---

## Vitest configuration for React 19 + Vite 7 + Zustand 5

Vitest provides fast unit testing with excellent React 19 support. Use **Vitest 2.1.0+** for full compatibility.

### Complete setup

```bash
npm install -D vitest @vitejs/plugin-react @testing-library/react @testing-library/user-event @testing-library/jest-dom jsdom
```

**vitest.config.ts:**

```typescript
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    include: ['**/*.{test,spec}.{ts,tsx}'],
    reporters: ['default', 'json'],
    outputFile: './test-results.json',
  },
})
```

**src/test/setup.ts:**

```typescript
import { afterEach, vi } from 'vitest'
import { cleanup } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'

afterEach(() => cleanup())
vi.mock('zustand')
```

### Zustand store mocking

The simplest approach uses direct state manipulation in `beforeEach`:

```typescript
import { useTimelineStore } from '../stores/timelineStore'

describe('Timeline ripple edit', () => {
  beforeEach(() => {
    useTimelineStore.setState({
      regions: [
        { id: 'A', startTime: 0, duration: 5 },
        { id: 'B', startTime: 10, duration: 5 },
        { id: 'C', startTime: 20, duration: 5 },
      ],
    })
  })
})
```

### Simulating drag with pointer events

Since jsdom lacks layout, use `fireEvent` with explicit coordinates and **assert on state changes rather than DOM positions**:

```typescript
import { render, screen, fireEvent } from '@testing-library/react'
import { useTimelineStore } from '../stores/timelineStore'
import { Timeline } from './Timeline'

it('performs ripple edit when dragging region A', async () => {
  render(<Timeline />)
  const regionA = screen.getByTestId('region-A')

  // Simulate pointer sequence
  fireEvent.pointerDown(regionA, {
    pointerId: 1,
    clientX: 0,
    clientY: 25,
    button: 0,
    buttons: 1,
  })

  fireEvent.pointerMove(regionA, {
    pointerId: 1,
    clientX: 100, // 100px = 10 seconds at 10px/sec
    clientY: 25,
    buttons: 1,
  })

  fireEvent.pointerUp(regionA, {
    pointerId: 1,
    clientX: 100,
    clientY: 25,
  })

  // Assert on Zustand state—the source of truth
  const state = useTimelineStore.getState()
  expect(state.regions).toEqual([
    { id: 'A', startTime: 10, duration: 5 },
    { id: 'B', startTime: 20, duration: 5 },
    { id: 'C', startTime: 30, duration: 5 },
  ])
})
```

Claude Code runs tests via `npx vitest run` and parses the JSON output in `test-results.json` for pass/fail analysis with specific assertion failures.

---

## Storybook interaction testing with official MCP integration

Storybook 10.1.x officially supports React 19 and offers an **MCP addon for Claude Code integration**—unique among testing tools.

### Setup for React 19 + Vite

```bash
npx storybook@latest init
npm install @storybook/addon-mcp
```

**Configure in .storybook/main.ts:**

```typescript
const config: StorybookConfig = {
  framework: '@storybook/react-vite',
  stories: ['../src/**/*.stories.@(ts|tsx)'],
  addons: [
    '@storybook/addon-essentials',
    '@storybook/addon-interactions',
    '@storybook/addon-mcp',
  ],
}
```

### MCP integration with Claude Code

When Storybook runs, it exposes an MCP server at `http://localhost:6006/mcp`:

```bash
claude mcp add storybook-mcp --transport http http://localhost:6006/mcp --scope project
```

This enables Claude to list components, view stories, and capture screenshots directly.

### Play functions for drag testing

Storybook's `userEvent` lacks built-in drag support, so use `fireEvent`:

```typescript
import type { Meta, StoryObj } from '@storybook/react-vite'
import { expect } from 'storybook/test'
import { fireEvent } from '@testing-library/dom'
import { useTimelineStore } from '../stores/timelineStore'
import { Timeline } from './Timeline'

const meta: Meta<typeof Timeline> = {
  component: Timeline,
}

export const DragTest: StoryObj<typeof Timeline> = {
  play: async ({ mount, step }) => {
    await step('Set initial Zustand state', () => {
      useTimelineStore.setState({
        regions: [
          { id: 'A', startTime: 0, duration: 5 },
          { id: 'B', startTime: 10, duration: 5 },
          { id: 'C', startTime: 20, duration: 5 },
        ],
      })
    })

    const canvas = await mount()

    await step('Drag region A', () => {
      const region = canvas.getByTestId('region-A')
      const rect = region.getBoundingClientRect()
      
      fireEvent.mouseDown(region, { clientX: rect.left + 10, clientY: rect.top + 10 })
      fireEvent.mouseMove(region, { clientX: rect.left + 110, clientY: rect.top + 10 })
      fireEvent.mouseUp(region)
    })

    await step('Verify ripple edit', async () => {
      const state = useTimelineStore.getState()
      await expect(state.regions[0].startTime).toBe(10)
    })
  },
}
```

### Visual regression with Chromatic

Chromatic (by Storybook maintainers) captures screenshots after play functions complete, enabling visual comparison of before/after states. Free tier includes **5,000 snapshots/month**.

---

## Cypress component testing offers best visual debugging for drags

Cypress provides superior **time-travel debugging** that lets you step through drag operations visually—invaluable for debugging complex gesture sequences.

### Installation

```bash
npm install -D cypress cypress-real-events
npx cypress open  # Select "Component Testing" → React → Vite
```

**cypress.config.ts:**

```typescript
import { defineConfig } from 'cypress'

export default defineConfig({
  component: {
    devServer: {
      framework: 'react',
      bundler: 'vite',
    },
  },
})
```

**cypress/support/component.ts:**

```typescript
import { mount } from 'cypress/react'
import 'cypress-real-events'

Cypress.Commands.add('mount', mount)
```

### cypress-real-events for native pointer events

This plugin fires events via Chrome DevTools Protocol, producing **trusted events** (`event.isTrusted = true`) that match real user interactions:

```typescript
import { useTimelineStore } from '../stores/timelineStore'
import Timeline from './Timeline'

describe('Timeline ripple edit', () => {
  beforeEach(() => {
    useTimelineStore.setState({
      regions: [
        { id: 'A', position: 0 },
        { id: 'B', position: 10 },
        { id: 'C', position: 20 },
      ],
    }, true)
  })

  it('shifts regions via ripple edit', () => {
    cy.mount(<Timeline />)
    
    // Real pointer events via CDP
    cy.get('[data-cy=region-A]').realMouseDown({ position: 'center' })
    cy.get('[data-cy=timeline-track]').realMouseMove(100, 0)
    cy.get('[data-cy=timeline-track]').realMouseUp()
    
    // Assert on Zustand state
    cy.window()
      .its('store')
      .invoke('getState')
      .its('regions')
      .should('deep.equal', [
        { id: 'A', position: 10 },
        { id: 'B', position: 20 },
        { id: 'C', position: 30 },
      ])
  })
})
```

For Claude Code to access the store, expose it on window during development:

```typescript
// In your store file
if (typeof window !== 'undefined' && window.Cypress) {
  window.store = useTimelineStore
}
```

### Time-travel debugging

Cypress captures DOM snapshots at every command. Hover over any step in the Command Log to see exact application state at that moment—essential for debugging why a drag operation didn't produce expected results.

---

## Essential additional tools for comprehensive testing

### Zustand devtools for state visualization

Add the devtools middleware to see state changes in Redux DevTools during development:

```typescript
import { create } from 'zustand'
import { devtools } from 'zustand/middleware'

export const useTimelineStore = create<TimelineStore>()(
  devtools(
    (set) => ({
      regions: [],
      moveRegion: (id, newPosition) => set(
        (state) => ({ /* update logic */ }),
        undefined,
        'timeline/moveRegion'  // Action name in devtools
      ),
    }),
    { name: 'TimelineStore' }
  )
)
```

### user-event vs fireEvent for pointer sequences

| Aspect | user-event | fireEvent |
|--------|------------|-----------|
| Realism | High (simulates full interaction) | Low (single event) |
| Drag support | Limited pointer API | Full control |
| jsdom compatibility | Checks visibility | No checks |
| **Recommendation** | Standard clicks, typing | **Complex drag sequences** |

For your timeline's `pointerdown → pointermove → pointerup` sequences, **use fireEvent**. user-event's pointer API doesn't fully support drag operations in jsdom.

### react-context-mcp for live state inspection

This MCP server lets Claude inspect React component state during manual testing:

```json
{
  "mcpServers": {
    "react-context": {
      "command": "react-context-mcp",
      "args": ["--browserUrl", "http://localhost:9222"]
    }
  }
}
```

Launch Chrome with debugging enabled: `google-chrome --remote-debugging-port=9222`

---

## Recommended testing strategy for your timeline component

Based on your specific requirements (drag operations, Zustand state, ripple edit logic, Claude Code integration), here's the recommended approach:

### Tier 1: Unit tests with Vitest (fast, runs on every save)

Test ripple-edit **state logic** independent of UI:

```typescript
// Pure logic test—no rendering needed
it('ripple edit shifts subsequent regions', () => {
  useTimelineStore.setState({
    regions: [
      { id: 'A', startTime: 0 },
      { id: 'B', startTime: 10 },
      { id: 'C', startTime: 20 },
    ],
  })
  
  useTimelineStore.getState().moveRegionWithRipple('A', 5)
  
  const { regions } = useTimelineStore.getState()
  expect(regions.map(r => r.startTime)).toEqual([5, 15, 25])
})
```

### Tier 2: Component tests with Vitest for integration

Test that UI dispatches correct state updates:

```typescript
it('drag gesture triggers ripple edit', () => {
  render(<Timeline />)
  const region = screen.getByTestId('region-A')
  
  fireEvent.pointerDown(region, { clientX: 0, pointerId: 1 })
  fireEvent.pointerMove(region, { clientX: 50, pointerId: 1 })
  fireEvent.pointerUp(region, { pointerId: 1 })
  
  expect(useTimelineStore.getState().regions[0].startTime).toBe(5)
})
```

### Tier 3: Visual E2E tests with Playwright MCP (Claude Code invoked)

Verify actual rendered positions in real browser:

```javascript
// Claude Code runs this via Playwright MCP
browser_navigate({ url: 'http://localhost:5173' })

browser_run_code({
  code: `
    // Set initial state
    await page.evaluate(() => {
      window.__ZUSTAND_STORE__.setState({
        regions: [
          { id: 'A', startTime: 0 },
          { id: 'B', startTime: 10 },
          { id: 'C', startTime: 20 },
        ]
      });
    });
    
    // Perform drag
    const regionA = page.locator('[data-testid="region-A"]');
    const box = await regionA.boundingBox();
    await page.mouse.move(box.x + 10, box.y + 10);
    await page.mouse.down();
    await page.mouse.move(box.x + 110, box.y + 10, { steps: 10 });
    await page.mouse.up();
  `
})

browser_take_screenshot({ fullPage: false })

browser_evaluate({
  function: `() => window.__ZUSTAND_STORE__.getState().regions`
})
```

### Quick reference: Tool selection by need

| Need | Tool | Why |
|------|------|-----|
| Fast state logic tests | Vitest | Sub-second feedback |
| Component integration | Vitest + fireEvent | Tests UI→state connection |
| Visual drag verification | Playwright MCP | Real browser, Claude can see screenshots |
| Interactive debugging | Cypress | Time-travel, visual runner |
| Story-driven development | Storybook + MCP addon | Claude can browse components |
| State change visualization | Zustand devtools | Redux DevTools integration |

All tools install as dev dependencies via npm and won't impact your single HTML production build. Run Vitest tests with `npx vitest run`, Cypress with `npx cypress run --component`, and Playwright MCP operations through Claude Code's tool invocation.