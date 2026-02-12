/**
 * E2E Tests for Timeline Viewport Interactions
 * Tests pan gestures, zoom controls, and selection mode toggle
 */

import { test, expect, Page } from '@playwright/test';

// ============================================
// Test Helpers
// ============================================

async function setupViewportTest(page: Page) {
  await page.waitForFunction(
    () => (window as any).__REAPER_STORE__ !== undefined,
    { timeout: 10000 }
  );

  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.getState()._setTestMode(true);
  });

  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.setState({
      connected: true,
      duration: 120,
      regions: [
        { id: 0, name: 'Intro', start: 0, end: 15, color: 0xff0000 },
        { id: 1, name: 'Verse', start: 15, end: 45, color: 0x00ff00 },
        { id: 2, name: 'Chorus', start: 45, end: 75, color: 0x0000ff },
        { id: 3, name: 'Bridge', start: 75, end: 90, color: 0xffff00 },
        { id: 4, name: 'Outro', start: 90, end: 120, color: 0xff00ff },
      ],
      markers: [
        { id: 0, name: 'Start', position: 0, color: 0xffffff },
        { id: 1, name: 'Drop', position: 45, color: 0xffffff },
        { id: 2, name: 'End', position: 120, color: 0xffffff },
      ],
      items: [],
      tracks: {},
      timelineMode: 'navigate',
      positionSeconds: 0,
      bpm: 120,
    });
  });

  await page.waitForTimeout(100);
}

async function getTimeline(page: Page) {
  return page.locator('[data-testid="timeline-canvas"]');
}

/**
 * Open the zoom popover (required before clicking zoom in/out buttons).
 * The zoom controls are behind a popover triggered by [aria-label="Open zoom controls"].
 */
async function openZoomPopover(page: Page) {
  await page.click('[aria-label="Open zoom controls"]');
  // Wait for the popover to render
  await page.waitForSelector('[aria-label="Zoom in"]', { timeout: 5000 });
}

/**
 * Click "Zoom in" button (opens popover first if needed).
 */
async function clickZoomIn(page: Page) {
  // If the popover isn't open, open it
  const zoomInButton = page.locator('[aria-label="Zoom in"]');
  if ((await zoomInButton.count()) === 0) {
    await openZoomPopover(page);
  }
  await zoomInButton.click();
}

/**
 * Click "Zoom out" button (opens popover first if needed).
 */
async function clickZoomOut(page: Page) {
  const zoomOutButton = page.locator('[aria-label="Zoom out"]');
  if ((await zoomOutButton.count()) === 0) {
    await openZoomPopover(page);
  }
  await zoomOutButton.click();
}

/**
 * Drag the timeline using pointer events.
 * The component uses onPointerDown/Move/Up (not mouse events).
 */
async function dragTimeline(page: Page, fromPercent: number, toPercent: number) {
  const timeline = await getTimeline(page);
  const box = await timeline.boundingBox();
  if (!box) throw new Error('Timeline not found');

  const startX = box.x + (box.width * fromPercent) / 100;
  const endX = box.x + (box.width * toPercent) / 100;
  const y = box.y + box.height / 2;

  await page.mouse.move(startX, y);
  await page.mouse.down();
  await page.mouse.move(endX, y, { steps: 10 });
  await page.mouse.up();
}

/**
 * Zoom in to create a viewport smaller than the full project.
 * The viewport initializes to show the full project (~122s), so panning has
 * no effect until we zoom in first (clampRange prevents scrolling when
 * visibleDuration >= projectDuration).
 */
async function zoomInForPan(page: Page) {
  // Zoom in several times to create a meaningfully smaller viewport
  await openZoomPopover(page);
  for (let i = 0; i < 3; i++) {
    await page.click('[aria-label="Zoom in"]');
    await page.waitForTimeout(50);
  }
  // Wait for viewport to settle
  await page.waitForTimeout(100);
}

// ============================================
// Pan Gesture Tests
// ============================================

test.describe('Viewport Pan Gestures', () => {
  test.use({ viewport: { width: 1024, height: 768 } });

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupViewportTest(page);
  });

  test('drag left pans viewport forward in time', async ({ page }) => {
    // Must zoom in first -- at full zoom the viewport covers the entire project
    // and clampRange prevents panning beyond project bounds
    await zoomInForPan(page);

    const timeline = await getTimeline(page);
    const initialScrollX = await timeline.getAttribute('data-scroll-x');

    await dragTimeline(page, 50, 25);

    const newScrollX = await timeline.getAttribute('data-scroll-x');
    expect(parseFloat(newScrollX!)).toBeGreaterThan(parseFloat(initialScrollX!));
  });

  test('drag right pans viewport backward in time', async ({ page }) => {
    // Zoom in and pan forward first to have room to pan back
    await zoomInForPan(page);
    await dragTimeline(page, 50, 25);
    await page.waitForTimeout(50);

    const timeline = await getTimeline(page);
    const initialScrollX = await timeline.getAttribute('data-scroll-x');

    await dragTimeline(page, 50, 75);

    const newScrollX = await timeline.getAttribute('data-scroll-x');
    expect(parseFloat(newScrollX!)).toBeLessThan(parseFloat(initialScrollX!));
  });

  test('pan respects project bounds (no negative start)', async ({ page }) => {
    // Zoom in first so panning is possible
    await zoomInForPan(page);

    // Try to pan backward past start (drag right)
    await dragTimeline(page, 25, 90);

    const timeline = await getTimeline(page);
    const scrollX = await timeline.getAttribute('data-scroll-x');
    expect(parseFloat(scrollX!)).toBeGreaterThanOrEqual(0);
  });

  test('vertical drag cancels pan gesture', async ({ page }) => {
    // Zoom in so pan would normally work
    await zoomInForPan(page);

    const timeline = await getTimeline(page);
    const box = await timeline.boundingBox();
    if (!box) throw new Error('Timeline not found');

    const initialScrollX = await timeline.getAttribute('data-scroll-x');

    const startX = box.x + box.width / 2;
    const startY = box.y + box.height / 2;

    await page.mouse.move(startX, startY);
    await page.mouse.down();
    // Move 60px down (exceeds 50px threshold)
    await page.mouse.move(startX + 50, startY + 60, { steps: 5 });
    await page.mouse.up();

    const newScrollX = await timeline.getAttribute('data-scroll-x');
    expect(newScrollX).toBe(initialScrollX);
  });
});

// ============================================
// Zoom Tests
// ============================================

test.describe('Viewport Zoom Controls', () => {
  test.use({ viewport: { width: 1024, height: 768 } });

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupViewportTest(page);
  });

  test('zoom in decreases visible duration', async ({ page }) => {
    const timeline = await getTimeline(page);
    const initialDuration = await timeline.getAttribute('data-visible-duration');

    await clickZoomIn(page);

    const newDuration = await timeline.getAttribute('data-visible-duration');
    expect(parseFloat(newDuration!)).toBeLessThan(parseFloat(initialDuration!));
  });

  test('zoom out increases visible duration', async ({ page }) => {
    // Zoom in first so there's room to zoom out
    await clickZoomIn(page);
    await page.waitForTimeout(50);

    const timeline = await getTimeline(page);
    const initialDuration = await timeline.getAttribute('data-visible-duration');

    await clickZoomOut(page);

    const newDuration = await timeline.getAttribute('data-visible-duration');
    expect(parseFloat(newDuration!)).toBeGreaterThan(parseFloat(initialDuration!));
  });

  test('fit-to-content shows full project', async ({ page }) => {
    // Zoom in first
    await clickZoomIn(page);
    await clickZoomIn(page);

    // Then fit to content
    await page.click('[aria-label="Fit to content"]');

    const timeline = await getTimeline(page);
    const duration = await timeline.getAttribute('data-visible-duration');
    // Should show most of the ~122s project (120s + padding)
    expect(parseFloat(duration!)).toBeGreaterThanOrEqual(100);
  });

  test('zoom reaches minimum level and stops changing', async ({ page }) => {
    // Zoom in repeatedly until the visible duration stops decreasing
    await openZoomPopover(page);

    let previousDuration = Infinity;
    for (let i = 0; i < 15; i++) {
      await page.click('[aria-label="Zoom in"]');
      await page.waitForTimeout(50);

      const timeline = await getTimeline(page);
      const currentDuration = parseFloat(
        (await timeline.getAttribute('data-visible-duration')) || '0'
      );

      // If duration stopped changing, we've hit the limit
      if (currentDuration === previousDuration) break;
      previousDuration = currentDuration;
    }

    // At the minimum zoom step (1 second), further zoom-ins should not change the duration
    const timeline = await getTimeline(page);
    const durationAtLimit = parseFloat(
      (await timeline.getAttribute('data-visible-duration')) || '0'
    );

    await page.click('[aria-label="Zoom in"]');
    await page.waitForTimeout(50);

    const durationAfterExtraClick = parseFloat(
      (await timeline.getAttribute('data-visible-duration')) || '0'
    );

    expect(durationAfterExtraClick).toBe(durationAtLimit);
  });

  test('zoom level attribute updates correctly', async ({ page }) => {
    const timeline = await getTimeline(page);
    const initialLevel = await timeline.getAttribute('data-zoom-level');

    await clickZoomIn(page);

    const newLevel = await timeline.getAttribute('data-zoom-level');
    // Zoom in = smaller duration = lower zoom level index
    expect(parseInt(newLevel!)).toBeLessThan(parseInt(initialLevel!));
  });
});

// ============================================
// Selection Mode Tests
// ============================================

test.describe('Selection Mode Toggle', () => {
  test.use({ viewport: { width: 1024, height: 768 } });

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupViewportTest(page);
  });

  test('toggle button shows correct aria-pressed state', async ({ page }) => {
    const toggle = page.locator('[data-testid="selection-toggle"]');

    // Initial: pan mode (not pressed)
    await expect(toggle).toHaveAttribute('aria-pressed', 'false');

    // Click to enable selection mode
    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-pressed', 'true');

    // Click again to disable
    await toggle.click();
    await expect(toggle).toHaveAttribute('aria-pressed', 'false');
  });

  test('data attribute reflects selection mode state', async ({ page }) => {
    const timeline = await getTimeline(page);

    // Initial: pan mode
    await expect(timeline).toHaveAttribute('data-selection-mode', 'false');

    // Enable selection mode
    await page.click('[data-testid="selection-toggle"]');

    await expect(timeline).toHaveAttribute('data-selection-mode', 'true');
  });

  test('drag creates time selection in selection mode', async ({ page }) => {
    // Enable selection mode
    await page.click('[data-testid="selection-toggle"]');
    await page.waitForTimeout(50);

    // Drag to create selection
    await dragTimeline(page, 25, 75);

    // Verify visual selection element appears
    const selectionElement = page.locator('[data-testid="time-selection"]');
    await expect(selectionElement).toBeVisible();

    // Check time selection was created in store
    const selection = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().timeSelection;
    });

    expect(selection).not.toBeNull();
    expect(selection.startSeconds).toBeLessThan(selection.endSeconds);

    // Verify the selection covers a reasonable time range (25%-75% of visible duration)
    const timeline = await getTimeline(page);
    const visibleDuration = parseFloat(
      (await timeline.getAttribute('data-visible-duration')) || '0'
    );
    const expectedMinDuration = visibleDuration * 0.3; // At least 30% of visible
    const actualDuration = selection.endSeconds - selection.startSeconds;
    expect(actualDuration).toBeGreaterThan(expectedMinDuration);
  });

  test('drag pans viewport in pan mode (default)', async ({ page }) => {
    // Ensure we're in pan mode (default)
    const toggle = page.locator('[data-testid="selection-toggle"]');
    await expect(toggle).toHaveAttribute('aria-pressed', 'false');

    // Must zoom in first -- at full zoom the viewport covers the entire project
    // and clampRange prevents panning beyond project bounds
    await zoomInForPan(page);

    const timeline = await getTimeline(page);
    const initialScrollX = await timeline.getAttribute('data-scroll-x');

    // Drag should pan, not select
    await dragTimeline(page, 50, 25);

    const newScrollX = await timeline.getAttribute('data-scroll-x');
    expect(newScrollX).not.toBe(initialScrollX);

    // No time selection should be created
    const selection = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().timeSelection;
    });
    expect(selection).toBeNull();
  });
});

// ============================================
// Accessibility Tests
// ============================================

test.describe('Accessibility: Reduced Motion', () => {
  test('respects prefers-reduced-motion setting for CSS animations', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });

    await page.goto('/');
    await setupViewportTest(page);

    // Check that animate-pulse elements have no/minimal animation
    const animatedElement = page.locator('.animate-pulse').first();

    if ((await animatedElement.count()) > 0) {
      const animationDuration = await animatedElement.evaluate((el) => {
        return window.getComputedStyle(el).animationDuration;
      });

      // Should be 0.01ms (our reduced motion override) or 0s
      expect(parseFloat(animationDuration)).toBeLessThan(0.1);
    }
  });

  test('zoom completes instantly with reduced motion', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });

    await page.goto('/');
    await setupViewportTest(page);

    const timeline = await getTimeline(page);
    const initialDuration = parseFloat(
      (await timeline.getAttribute('data-visible-duration')) || '0'
    );

    // Click zoom in (must open popover first)
    await clickZoomIn(page);

    // With reduced motion, zoom should be instant (no animation delay)
    // Check immediately - no need to wait for animation
    const newDuration = parseFloat(
      (await timeline.getAttribute('data-visible-duration')) || '0'
    );

    // Duration should have already changed (instant snap, not animated)
    expect(newDuration).toBeLessThan(initialDuration);
  });

  test('transitions are disabled with reduced motion', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });

    await page.goto('/');
    await setupViewportTest(page);

    // Check that transition-* classes have no transition
    const transitionElement = page.locator('.transition-colors, .transition-opacity').first();

    if ((await transitionElement.count()) > 0) {
      const transitionDuration = await transitionElement.evaluate((el) => {
        return window.getComputedStyle(el).transitionDuration;
      });

      // Should be 0s or 0.01ms (our reduced motion override)
      expect(parseFloat(transitionDuration)).toBeLessThan(0.02);
    }
  });
});
