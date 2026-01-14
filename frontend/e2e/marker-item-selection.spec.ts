/**
 * Marker/Item Selection E2E Tests
 *
 * Tests the mutual exclusion between marker and item selection in Navigate mode.
 * - Tapping an item selects it and clears marker selection
 * - Tapping a marker selects it and clears item selection
 * - When nothing is selected, fallback message shows
 */

import { test, expect, Page } from '@playwright/test';

// Wait for store to be available and inject test fixtures
async function setupTestFixtures(page: Page) {
  // Wait for the store to be exposed on window
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  });

  // Enable test mode FIRST - prevents WebSocket from overwriting connection state
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.getState()._setTestMode(true);
  });

  // Inject test data
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;

    // Set localStorage to navigate mode
    localStorage.setItem('reamo-timeline-mode', 'navigate');

    // Set raw data
    store.setState({
      // Bypass loading screen
      connected: true,

      // Navigate mode
      timelineMode: 'navigate',

      // Test markers: one at 5s, one at 15s
      markers: [
        { id: 1, name: 'Intro', position: 5, color: 0xff0000 },
        { id: 2, name: 'Verse', position: 15, color: 0x00ff00 },
      ],

      // Test regions
      regions: [
        { id: 0, name: 'Full', start: 0, end: 30, color: 0x0000ff },
      ],

      // Test items: one item from 3s-7s on track 0 (overlaps marker 1 at 5s)
      // Another item from 10s-14s on track 1 (no marker overlap)
      items: [
        {
          trackIdx: 0,
          itemIdx: 0,
          position: 3,
          length: 4,
          guid: '{item-1-guid}',
          activeTakeIdx: 0,
          takeCount: 1,
          takeName: 'Item 1',
          color: 0x888888,
        },
        {
          trackIdx: 1,
          itemIdx: 0,
          position: 10,
          length: 4,
          guid: '{item-2-guid}',
          activeTakeIdx: 0,
          takeCount: 1,
          takeName: 'Item 2',
          color: 0x999999,
        },
      ],

      // Test tracks
      tracks: {
        0: { index: 0, name: 'Track 1', guid: '{track-0-guid}', color: 0x444444 },
        1: { index: 1, name: 'Track 2', guid: '{track-1-guid}', color: 0x555555 },
      },

      // Set position away from markers initially
      positionSeconds: 0,

      // Reset selection state - NOTHING selected initially
      selectedMarkerId: null,
      selectedItemKey: null,
      isMarkerLocked: false,
    });

    // Use store action to switch to navigate mode
    store.getState().setTimelineMode('navigate');
  });

  // Wait for component to re-render
  await page.waitForTimeout(100);
}

// Get the timeline container
async function getTimelineContainer(page: Page) {
  return page.locator('[data-testid="timeline-canvas"]');
}

// Click at a percentage position in the timeline
async function clickAtPercent(page: Page, percent: number) {
  const timeline = await getTimelineContainer(page);
  const box = await timeline.boundingBox();
  if (!box) throw new Error('Timeline container not found');

  const relativeX = (box.width * percent) / 100;
  const relativeY = box.height / 2;

  await timeline.click({ position: { x: relativeX, y: relativeY } });
}

// Get marker pills container (bottom bar below timeline)
function getMarkerPillsBar(page: Page) {
  // The marker pills are in a bar below the timeline canvas
  return page.locator('.bg-bg-deep').filter({ hasText: /Intro|Verse/ }).first();
}

test.describe('Marker/Item Selection', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupTestFixtures(page);
  });

  test('shows "nothing selected" message when nothing is selected', async ({ page }) => {
    // Initially nothing should be selected (we set selectedMarkerId: null, selectedItemKey: null)
    const nothingSelectedMsg = page.locator('[data-testid="nothing-selected-message"]');
    await expect(nothingSelectedMsg).toBeVisible({ timeout: 5000 });
    await expect(nothingSelectedMsg).toContainText('Tap a marker pill or item blob');

    // MarkerInfoBar should not be visible
    const markerInfoBar = page.locator('[data-testid="marker-info-bar"]');
    await expect(markerInfoBar).not.toBeVisible();

    // ItemInfoBar should not be visible
    const itemInfoBar = page.locator('[data-testid="item-info-bar"]');
    await expect(itemInfoBar).not.toBeVisible();
  });

  test('tapping item blob selects item and shows ItemInfoBar', async ({ page }) => {
    // First verify nothing is selected
    await expect(page.locator('[data-testid="nothing-selected-message"]')).toBeVisible({ timeout: 5000 });

    // Click at position where item 1 is (3-7s, approximately 10-23% of 30s timeline)
    // Item 1 is at 3-7s out of 30s = 10-23% of timeline
    // Let's click at 16% (around 4.8s, within the item)
    await clickAtPercent(page, 16);

    // Small wait for state update
    await page.waitForTimeout(100);

    // Verify item is selected in store
    const selectedItemKey = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().selectedItemKey;
    });
    expect(selectedItemKey).toBe('0:0'); // trackIdx:itemIdx

    // ItemInfoBar should be visible
    const itemInfoBar = page.locator('[data-testid="item-info-bar"]');
    await expect(itemInfoBar).toBeVisible({ timeout: 2000 });

    // MarkerInfoBar should not be visible (mutual exclusion)
    const markerInfoBar = page.locator('[data-testid="marker-info-bar"]');
    await expect(markerInfoBar).not.toBeVisible();

    // Nothing selected message should not be visible
    const nothingSelectedMsg = page.locator('[data-testid="nothing-selected-message"]');
    await expect(nothingSelectedMsg).not.toBeVisible();
  });

  test('selecting marker clears item selection', async ({ page }) => {
    // First select an item via store
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().selectItem(0, 0);
    });

    await page.waitForTimeout(50);

    // Verify item is selected
    let selectedItemKey = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().selectedItemKey;
    });
    expect(selectedItemKey).toBe('0:0');

    // Now select a marker via store (simulates tapping marker pill)
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().setSelectedMarkerId(1);
    });

    await page.waitForTimeout(50);

    // Verify marker is selected and item is cleared
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        selectedMarkerId: s.selectedMarkerId,
        selectedItemKey: s.selectedItemKey,
      };
    });

    expect(state.selectedMarkerId).toBe(1);
    expect(state.selectedItemKey).toBeNull();

    // MarkerInfoBar should be visible
    const markerInfoBar = page.locator('[data-testid="marker-info-bar"]');
    await expect(markerInfoBar).toBeVisible();

    // ItemInfoBar should not be visible
    const itemInfoBar = page.locator('[data-testid="item-info-bar"]');
    await expect(itemInfoBar).not.toBeVisible();
  });

  test('selecting item clears marker selection', async ({ page }) => {
    // First select a marker via store
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().setSelectedMarkerId(1);
    });

    await page.waitForTimeout(50);

    // Verify marker is selected
    let selectedMarkerId = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().selectedMarkerId;
    });
    expect(selectedMarkerId).toBe(1);

    // MarkerInfoBar should be visible
    await expect(page.locator('[data-testid="marker-info-bar"]')).toBeVisible();

    // Now select an item via store (simulates tapping item blob)
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().selectItem(1, 0);
    });

    await page.waitForTimeout(50);

    // Verify item is selected and marker is cleared
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        selectedMarkerId: s.selectedMarkerId,
        selectedItemKey: s.selectedItemKey,
      };
    });

    expect(state.selectedMarkerId).toBeNull();
    expect(state.selectedItemKey).toBe('1:0');

    // ItemInfoBar should be visible
    const itemInfoBar = page.locator('[data-testid="item-info-bar"]');
    await expect(itemInfoBar).toBeVisible();

    // MarkerInfoBar should not be visible
    const markerInfoBar = page.locator('[data-testid="marker-info-bar"]');
    await expect(markerInfoBar).not.toBeVisible();
  });

  test('tapping empty area in timeline does not affect selection', async ({ page }) => {
    // First select an item
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().selectItem(0, 0);
    });

    await page.waitForTimeout(50);

    // Verify item is selected
    await expect(page.locator('[data-testid="item-info-bar"]')).toBeVisible();

    // Click at position where no item exists (90% of timeline, around 27s)
    await clickAtPercent(page, 90);

    await page.waitForTimeout(100);

    // Item should still be selected (tapping empty space doesn't deselect)
    // Actually this behavior may vary - let's check what happens
    const selectedItemKey = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().selectedItemKey;
    });

    // Note: The current implementation doesn't clear selection on empty tap
    // This test documents the current behavior
    expect(selectedItemKey).toBe('0:0');
  });

  test('item density overlay renders with testid', async ({ page }) => {
    // The density overlay should be visible when items exist
    const densityOverlay = page.locator('[data-testid="item-density-overlay"]');
    await expect(densityOverlay).toBeVisible({ timeout: 5000 });
  });

  test('info section renders with testid in navigate mode', async ({ page }) => {
    const infoSection = page.locator('[data-testid="navigate-info-section"]');
    await expect(infoSection).toBeVisible({ timeout: 5000 });
  });
});

test.describe('Marker/Item overlap', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupTestFixtures(page);
  });

  test('clicking marker pill when item exists at same position selects marker (not item)', async ({ page }) => {
    // Reset selection
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.setState({
        selectedMarkerId: null,
        selectedItemKey: null,
        isMarkerLocked: false,
      });
    });

    await page.waitForTimeout(50);

    // Verify nothing selected initially
    await expect(page.locator('[data-testid="nothing-selected-message"]')).toBeVisible({ timeout: 5000 });

    // Our fixture has:
    // - Marker 1 "Intro" at position 5s
    // - Item 1 from 3s-7s (overlaps marker 1)
    // So clicking on marker 1's pill should select the marker, NOT the item

    // Find and click the marker pill by its aria-label (marker pills show ID number, not name)
    // aria-label format: "Marker 1: Intro at 0:05"
    const markerPill = page.locator('[role="button"][aria-label*="Marker 1"]').first();
    await expect(markerPill).toBeVisible({ timeout: 5000 });
    await markerPill.click();

    await page.waitForTimeout(200);

    // Check store state - marker should be selected, not item
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        selectedMarkerId: s.selectedMarkerId,
        selectedItemKey: s.selectedItemKey,
      };
    });

    // EXPECTED: Marker selected, item NOT selected
    expect(state.selectedMarkerId).toBe(1);
    expect(state.selectedItemKey).toBeNull();

    // MarkerInfoBar should be visible
    await expect(page.locator('[data-testid="marker-info-bar"]')).toBeVisible();

    // ItemInfoBar should NOT be visible
    await expect(page.locator('[data-testid="item-info-bar"]')).not.toBeVisible();
  });

  test('clicking item blob when marker exists at same position selects item (not marker)', async ({ page }) => {
    // Reset selection
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.setState({
        selectedMarkerId: null,
        selectedItemKey: null,
        isMarkerLocked: false,
      });
    });

    await page.waitForTimeout(50);

    // Click on the timeline at 16% (around 4.8s) where item 1 exists (3-7s)
    // This is also near marker 1 at 5s
    await clickAtPercent(page, 16);

    await page.waitForTimeout(200);

    // Check store state - item should be selected, not marker
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        selectedMarkerId: s.selectedMarkerId,
        selectedItemKey: s.selectedItemKey,
      };
    });

    // EXPECTED: Item selected, marker cleared
    expect(state.selectedItemKey).toBe('0:0');
    expect(state.selectedMarkerId).toBeNull();
  });
});

test.describe('Item tap Y-bounds', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupTestFixtures(page);
  });

  test('tapping below item blob (but at same X) should NOT select item', async ({ page }) => {
    // Reset selection
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.setState({
        selectedMarkerId: null,
        selectedItemKey: null,
      });
    });

    await page.waitForTimeout(50);

    // Get the timeline canvas
    const timeline = page.locator('[data-testid="timeline-canvas"]');
    const box = await timeline.boundingBox();
    if (!box) throw new Error('Timeline not found');

    // Item 1 is at position 3-7s out of ~30s = 10-23% of timeline
    // Click at 16% horizontally (within item's time range)
    // But click at the BOTTOM of the timeline (Y = 90% of height)
    // This should NOT select the item because it's outside the blob's vertical bounds
    const clickX = box.width * 0.16;
    const clickY = box.height * 0.9; // Bottom of timeline, outside blob area

    await timeline.click({ position: { x: clickX, y: clickY } });

    await page.waitForTimeout(100);

    // Item should NOT be selected - we clicked below the blob
    const selectedItemKey = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().selectedItemKey;
    });

    expect(selectedItemKey).toBeNull();
  });

  test('tapping ON item blob (center Y) SHOULD select item', async ({ page }) => {
    // Reset selection
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.setState({
        selectedMarkerId: null,
        selectedItemKey: null,
      });
    });

    await page.waitForTimeout(50);

    const timeline = page.locator('[data-testid="timeline-canvas"]');
    const box = await timeline.boundingBox();
    if (!box) throw new Error('Timeline not found');

    // Click at 16% horizontally (within item's time range)
    // Click at CENTER of timeline (Y = 50% of height) - where the blob IS
    const clickX = box.width * 0.16;
    const clickY = box.height * 0.5; // Center of timeline, ON the blob

    await timeline.click({ position: { x: clickX, y: clickY } });

    await page.waitForTimeout(100);

    // Item SHOULD be selected - we clicked on the blob
    const selectedItemKey = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().selectedItemKey;
    });

    expect(selectedItemKey).toBe('0:0');
  });
});

test.describe('Item tap detection', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupTestFixtures(page);
  });

  test('clicking on item blob at correct position selects item', async ({ page }) => {
    // Reset to ensure nothing selected
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.setState({
        selectedMarkerId: null,
        selectedItemKey: null,
        isMarkerLocked: false,
      });
    });

    await page.waitForTimeout(50);

    // Verify nothing selected message
    await expect(page.locator('[data-testid="nothing-selected-message"]')).toBeVisible({ timeout: 5000 });

    // Item 1 is at position 3-7s (out of ~30s visible)
    // That's roughly 10-23% of the timeline
    // Click in the middle of item 1 at ~16%
    await clickAtPercent(page, 16);

    await page.waitForTimeout(200);

    // Check store state
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        selectedItemKey: s.selectedItemKey,
        selectedMarkerId: s.selectedMarkerId,
      };
    });

    // Item should be selected
    expect(state.selectedItemKey).toBe('0:0');
    expect(state.selectedMarkerId).toBeNull();
  });

  test('clicking between items does not select anything new', async ({ page }) => {
    // Reset selection
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.setState({
        selectedMarkerId: null,
        selectedItemKey: null,
      });
    });

    await page.waitForTimeout(50);

    // Click at 28% (~8.4s) - between item 1 (3-7s) and item 2 (10-14s)
    await clickAtPercent(page, 28);

    await page.waitForTimeout(200);

    // Should still have nothing selected (no item at this position)
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        selectedItemKey: s.selectedItemKey,
        selectedMarkerId: s.selectedMarkerId,
      };
    });

    expect(state.selectedItemKey).toBeNull();
  });

  test('clicking second item selects it', async ({ page }) => {
    // Reset selection
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.setState({
        selectedMarkerId: null,
        selectedItemKey: null,
      });
    });

    await page.waitForTimeout(50);

    // Item 2 is at position 10-14s (out of ~30s visible)
    // That's roughly 33-47% of the timeline
    // Click in the middle at ~40%
    await clickAtPercent(page, 40);

    await page.waitForTimeout(200);

    const selectedItemKey = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().selectedItemKey;
    });

    // Item 2 should be selected (trackIdx 1, itemIdx 0)
    expect(selectedItemKey).toBe('1:0');
  });
});
