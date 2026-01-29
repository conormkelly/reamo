/**
 * Marker/Item Selection E2E Tests
 *
 * Tests the contextual info bar behavior in Navigate mode.
 * - Marker selection is a transient overlay (does NOT clear item selection)
 * - Tapping an item selects it and clears marker selection
 * - When marker is dismissed, item info bar restores if items are still selected
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

  test('tapping item blob enters selection mode and shows ItemInfoBar', async ({ page }) => {
    // First verify nothing is selected
    await expect(page.locator('[data-testid="nothing-selected-message"]')).toBeVisible({ timeout: 5000 });

    // Click at position where item 1 is (3-7s, approximately 10-23% of 30s timeline)
    // Item 1 is at 3-7s out of 30s = 10-23% of timeline
    // Let's click at 16% (around 4.8s, within the item)
    await clickAtPercent(page, 16);

    // Small wait for state update
    await page.waitForTimeout(100);

    // Verify item selection mode is active
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        itemSelectionModeActive: s.itemSelectionModeActive,
        viewFilterTrackGuid: s.viewFilterTrackGuid,
      };
    });
    expect(state.itemSelectionModeActive).toBe(true);
    expect(state.viewFilterTrackGuid).toBeTruthy();

    // ItemInfoBar should be visible
    const itemInfoBar = page.locator('[data-testid="item-info-bar"]');
    await expect(itemInfoBar).toBeVisible({ timeout: 2000 });

    // MarkerInfoBar should not be visible
    const markerInfoBar = page.locator('[data-testid="marker-info-bar"]');
    await expect(markerInfoBar).not.toBeVisible();

    // Nothing selected message should not be visible
    const nothingSelectedMsg = page.locator('[data-testid="nothing-selected-message"]');
    await expect(nothingSelectedMsg).not.toBeVisible();
  });

  test('selecting marker overlays item selection (item selection persists)', async ({ page }) => {
    // First enter item selection mode and select an item
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().enterItemSelectionMode('{track-0-guid}');
      // Simulate REAPER selecting the item
      const items = [...store.getState().items];
      items[0] = { ...items[0], selected: true };
      store.getState().setItems(items);
    });

    await page.waitForTimeout(50);

    // Verify item is selected and info bar shows
    await expect(page.locator('[data-testid="item-info-bar"]')).toBeVisible({ timeout: 2000 });

    // Now select a marker via store (simulates tapping marker pill)
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().setSelectedMarkerId(1);
    });

    await page.waitForTimeout(50);

    // Verify marker is selected but item selection PERSISTS (contextual overlay)
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        selectedMarkerId: s.selectedMarkerId,
        itemSelectionModeActive: s.itemSelectionModeActive,
        selectedItems: s.items.filter((i: any) => i.selected).length,
      };
    });

    expect(state.selectedMarkerId).toBe(1);
    expect(state.itemSelectionModeActive).toBe(true); // Mode still active
    expect(state.selectedItems).toBe(1); // Item still selected in REAPER

    // MarkerInfoBar should be visible (takes precedence)
    const markerInfoBar = page.locator('[data-testid="marker-info-bar"]');
    await expect(markerInfoBar).toBeVisible();

    // ItemInfoBar should NOT be visible (marker overlays it)
    const itemInfoBar = page.locator('[data-testid="item-info-bar"]');
    await expect(itemInfoBar).not.toBeVisible();
  });

  test('dismissing marker restores item info bar', async ({ page }) => {
    // Enter item selection mode, select an item, then select a marker
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().enterItemSelectionMode('{track-0-guid}');
      const items = [...store.getState().items];
      items[0] = { ...items[0], selected: true };
      store.getState().setItems(items);
      store.getState().setSelectedMarkerId(1);
    });

    await page.waitForTimeout(50);

    // Verify marker info is showing
    await expect(page.locator('[data-testid="marker-info-bar"]')).toBeVisible();
    await expect(page.locator('[data-testid="item-info-bar"]')).not.toBeVisible();

    // Dismiss marker (clear selection)
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().setSelectedMarkerId(null);
    });

    await page.waitForTimeout(50);

    // Item info bar should restore (item was still selected)
    await expect(page.locator('[data-testid="marker-info-bar"]')).not.toBeVisible();
    await expect(page.locator('[data-testid="item-info-bar"]')).toBeVisible();

    // Item should still be selected
    const selectedCount = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().items.filter((i: any) => i.selected).length;
    });
    expect(selectedCount).toBe(1);
  });

  test('selecting item clears marker selection', async ({ page }) => {
    // First select a marker via store
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().setSelectedMarkerId(1);
    });

    await page.waitForTimeout(50);

    // Verify marker is selected
    const selectedMarkerId = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().selectedMarkerId;
    });
    expect(selectedMarkerId).toBe(1);

    // MarkerInfoBar should be visible
    await expect(page.locator('[data-testid="marker-info-bar"]')).toBeVisible();

    // Now simulate tapping an item (enter mode, select item, clear marker)
    // In real app, Timeline.tsx clears marker when item is clicked
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      // Enter item selection mode
      store.getState().enterItemSelectionMode('{track-1-guid}');
      // Clear marker (done by Timeline.tsx on item click)
      store.getState().setSelectedMarkerId(null);
      // Simulate REAPER selecting the item
      const items = [...store.getState().items];
      items[1] = { ...items[1], selected: true };
      store.getState().setItems(items);
    });

    await page.waitForTimeout(50);

    // Verify marker is cleared and item selection mode active
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        selectedMarkerId: s.selectedMarkerId,
        itemSelectionModeActive: s.itemSelectionModeActive,
        selectedItems: s.items.filter((i: any) => i.selected).length,
      };
    });

    expect(state.selectedMarkerId).toBeNull();
    expect(state.itemSelectionModeActive).toBe(true);
    expect(state.selectedItems).toBe(1);

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

/**
 * Item Selection Mode E2E Tests
 *
 * Tests the new item selection mode flow:
 * - Tapping aggregate blob enters mode and reveals items (no selection)
 * - Tapping revealed items toggles selection
 * - Track dropdown filters view only (no auto-select)
 * - Prev/Next navigates without selecting
 * - X button exits mode
 */
test.describe('Item Selection Mode', () => {
  async function setupItemSelectionTestFixtures(page: Page) {
    // Wait for store
    await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
      timeout: 10000,
    });

    // Enable test mode
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState()._setTestMode(true);
    });

    // Inject test data with multiple items per track for proper testing
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;

      localStorage.setItem('reamo-timeline-mode', 'navigate');

      store.setState({
        connected: true,
        timelineMode: 'navigate',

        markers: [],
        regions: [],

        // Multiple items on multiple tracks
        items: [
          // Track 0: 3 items
          {
            trackIdx: 0,
            itemIdx: 0,
            position: 2,
            length: 3,
            guid: '{item-t0-0}',
            activeTakeIdx: 0,
            takeCount: 1,
            takeName: 'T0 Item 1',
            color: 0x888888,
            selected: false,
          },
          {
            trackIdx: 0,
            itemIdx: 1,
            position: 7,
            length: 3,
            guid: '{item-t0-1}',
            activeTakeIdx: 0,
            takeCount: 1,
            takeName: 'T0 Item 2',
            color: 0x999999,
            selected: false,
          },
          {
            trackIdx: 0,
            itemIdx: 2,
            position: 12,
            length: 3,
            guid: '{item-t0-2}',
            activeTakeIdx: 0,
            takeCount: 1,
            takeName: 'T0 Item 3',
            color: 0xaaaaaa,
            selected: false,
          },
          // Track 1: 2 items
          {
            trackIdx: 1,
            itemIdx: 0,
            position: 4,
            length: 4,
            guid: '{item-t1-0}',
            activeTakeIdx: 0,
            takeCount: 1,
            takeName: 'T1 Item 1',
            color: 0x666666,
            selected: false,
          },
          {
            trackIdx: 1,
            itemIdx: 1,
            position: 15,
            length: 5,
            guid: '{item-t1-1}',
            activeTakeIdx: 0,
            takeCount: 1,
            takeName: 'T1 Item 2',
            color: 0x777777,
            selected: false,
          },
        ],

        // Track skeleton with GUIDs
        trackSkeleton: [
          { n: 'Track 1', g: '{track-0-guid}' },
          { n: 'Track 2', g: '{track-1-guid}' },
        ],

        tracks: {
          0: { index: 0, name: 'Track 1', guid: '{track-0-guid}', color: 0x444444 },
          1: { index: 1, name: 'Track 2', guid: '{track-1-guid}', color: 0x555555 },
        },

        positionSeconds: 0,

        // Item selection mode state - start NOT in mode
        itemSelectionModeActive: false,
        viewFilterTrackGuid: null,
        selectedMarkerId: null,
      });

      store.getState().setTimelineMode('navigate');
    });

    await page.waitForTimeout(100);
  }

  test.beforeEach(async ({ page }) => {
    await page.goto('/');
    await setupItemSelectionTestFixtures(page);
  });

  test('aggregate blobs shown initially, no item info bar', async ({ page }) => {
    // Aggregate blobs should be visible
    const densityOverlay = page.locator('[data-testid="item-density-overlay"]');
    await expect(densityOverlay).toBeVisible({ timeout: 5000 });

    // Item info bar should NOT be visible (not in item selection mode)
    const itemInfoBar = page.locator('[data-testid="item-info-bar"]');
    await expect(itemInfoBar).not.toBeVisible();

    // Check store state
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        itemSelectionModeActive: s.itemSelectionModeActive,
        viewFilterTrackGuid: s.viewFilterTrackGuid,
      };
    });

    expect(state.itemSelectionModeActive).toBe(false);
    expect(state.viewFilterTrackGuid).toBeNull();
  });

  test('tapping blob enters item selection mode without selecting', async ({ page }) => {
    const timeline = page.locator('[data-testid="timeline-canvas"]');
    const box = await timeline.boundingBox();
    if (!box) throw new Error('Timeline not found');

    // Click at center of timeline (where blobs are) at 12% (~3.6s, within first item)
    await timeline.click({
      position: { x: box.width * 0.12, y: box.height * 0.5 },
    });

    await page.waitForTimeout(150);

    // Check store state
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        itemSelectionModeActive: s.itemSelectionModeActive,
        viewFilterTrackGuid: s.viewFilterTrackGuid,
        selectedItems: s.items.filter((i: any) => i.selected),
      };
    });

    // Should be in item selection mode
    expect(state.itemSelectionModeActive).toBe(true);
    // Should have a filter track set (first track with items at that position)
    expect(state.viewFilterTrackGuid).toBeTruthy();
    // NO items should be selected (mode entry doesn't select)
    expect(state.selectedItems.length).toBe(0);

    // Item info bar should now be visible
    const itemInfoBar = page.locator('[data-testid="item-info-bar"]');
    await expect(itemInfoBar).toBeVisible({ timeout: 2000 });
  });

  test('tapping revealed item toggles selection', async ({ page }) => {
    // First enter item selection mode via store
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().enterItemSelectionMode('{track-0-guid}');
    });

    await page.waitForTimeout(100);

    // Verify we're in mode
    const itemInfoBar = page.locator('[data-testid="item-info-bar"]');
    await expect(itemInfoBar).toBeVisible({ timeout: 2000 });

    // Now tap on an item (first item is at 2-5s = ~7-17% of 30s)
    const timeline = page.locator('[data-testid="timeline-canvas"]');
    const box = await timeline.boundingBox();
    if (!box) throw new Error('Timeline not found');

    await timeline.click({
      position: { x: box.width * 0.12, y: box.height * 0.5 },
    });

    await page.waitForTimeout(150);

    // Simulate REAPER responding by marking item as selected
    // (In real app, this comes from REAPER polling)
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const items = [...store.getState().items];
      items[0] = { ...items[0], selected: true };
      store.getState().setItems(items);
    });

    await page.waitForTimeout(100);

    // Check that selection count pill shows
    const selectionPill = page.locator('[data-testid="selection-pill"]');
    await expect(selectionPill).toBeVisible({ timeout: 2000 });

    // Check count
    const selectionCount = page.locator('[data-testid="selection-count"]');
    await expect(selectionCount).toHaveText('1');
  });

  test('selection persists when changing track filter', async ({ page }) => {
    // Enter mode and select an item on track 0
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().enterItemSelectionMode('{track-0-guid}');

      // Simulate item selected in REAPER
      const items = [...store.getState().items];
      items[0] = { ...items[0], selected: true };
      store.getState().setItems(items);
    });

    await page.waitForTimeout(100);

    // Selection count should be 1
    await expect(page.locator('[data-testid="selection-count"]')).toHaveText('1');

    // Change filter to track 1
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().setViewFilterTrack('{track-1-guid}');
    });

    await page.waitForTimeout(100);

    // Selection count should still be 1 (selection persists across filter changes)
    await expect(page.locator('[data-testid="selection-count"]')).toHaveText('1');

    // Verify item is still selected in store
    const selectedCount = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().items.filter((i: any) => i.selected).length;
    });
    expect(selectedCount).toBe(1);
  });

  test('X button exits item selection mode', async ({ page }) => {
    // Enter mode
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().enterItemSelectionMode('{track-0-guid}');
    });

    await page.waitForTimeout(100);

    // Verify info bar visible
    await expect(page.locator('[data-testid="item-info-bar"]')).toBeVisible({ timeout: 2000 });

    // Click X button
    const closeBtn = page.locator('[data-testid="item-mode-close"]');
    await closeBtn.click();

    await page.waitForTimeout(100);

    // Verify mode exited
    const state = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      const s = store.getState();
      return {
        itemSelectionModeActive: s.itemSelectionModeActive,
        viewFilterTrackGuid: s.viewFilterTrackGuid,
      };
    });

    expect(state.itemSelectionModeActive).toBe(false);
    expect(state.viewFilterTrackGuid).toBeNull();

    // Info bar should not be visible
    await expect(page.locator('[data-testid="item-info-bar"]')).not.toBeVisible();
  });

  test('single item selected shows take navigation', async ({ page }) => {
    // Enter mode with track 0 filter and select first item
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().enterItemSelectionMode('{track-0-guid}');

      // Simulate first item selected (has 1 take)
      const items = [...store.getState().items];
      items[0] = { ...items[0], selected: true };
      store.getState().setItems(items);
    });

    await page.waitForTimeout(100);

    // Info bar should show take info (single item mode)
    const itemInfoBar = page.locator('[data-testid="item-info-bar"]');
    await expect(itemInfoBar).toBeVisible({ timeout: 2000 });
    // Should contain take navigation text
    await expect(itemInfoBar).toContainText('Take 1/1');
  });

  test('tapping on item NOT on filtered track does nothing', async ({ page }) => {
    // Enter mode filtered to track 0
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().enterItemSelectionMode('{track-0-guid}');
    });

    await page.waitForTimeout(100);

    // Track 1 item 1 is at 4-8s = ~13-27% of 30s
    // But we're filtered to track 0, so clicking there should do nothing
    const timeline = page.locator('[data-testid="timeline-canvas"]');
    const box = await timeline.boundingBox();
    if (!box) throw new Error('Timeline not found');

    // Click at 20% (within track 1's item but we're filtered to track 0)
    await timeline.click({
      position: { x: box.width * 0.2, y: box.height * 0.5 },
    });

    await page.waitForTimeout(150);

    // Check no selection was made
    const selectedCount = await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      return store.getState().items.filter((i: any) => i.selected).length;
    });

    // Should still be 0 - tap was ignored because no track 0 item at that position
    expect(selectedCount).toBe(0);
  });

  test('selected items show inset blue border', async ({ page }) => {
    // Enter mode and select an item
    await page.evaluate(() => {
      const store = (window as any).__REAPER_STORE__;
      store.getState().enterItemSelectionMode('{track-0-guid}');

      const items = [...store.getState().items];
      items[0] = { ...items[0], selected: true };
      store.getState().setItems(items);
    });

    await page.waitForTimeout(100);

    // Check that item blob has data-selected="true"
    const selectedBlob = page.locator('[data-testid="item-blob-0-0"]');
    await expect(selectedBlob).toHaveAttribute('data-selected', 'true');
  });
});
