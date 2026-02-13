/**
 * Notes View Connection State E2E Tests
 *
 * Tests for a bug where NotesView was creating a second WebSocket connection
 * by calling useReaperConnection() directly instead of using useReaper().
 * When navigating away from Notes, the second connection's cleanup would
 * incorrectly set connected=false in the store.
 *
 * Test mode: When _testMode is enabled in the store, both WebSocket messages
 * AND connection state changes are ignored, allowing tests to fully control state.
 */

import { test, expect, Page } from '@playwright/test';

// Wait for store and enable test mode to fully control state
async function setupTestMode(page: Page) {
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  });

  // Enable test mode FIRST - this prevents WebSocket from updating connection state
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.getState()._setTestMode(true);
  });

  // Now set our controlled test state
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.setState({
      connected: true,
      errorCount: 0,
      tracks: [
        { idx: 0, name: 'MASTER', volume: 1.0, pan: 0, color: 0, flags: 0 },
      ],
      regions: [],
      bpm: 120,
      timeSignatureNumerator: 4,
      timeSignatureDenominator: 4,
    });
  });

  // Wait for the app to fully render (default view is timeline)
  await page.waitForSelector('[data-view="timeline"]', { state: 'visible' });
}

// Helper to get connection state
async function getConnectionState(page: Page): Promise<boolean> {
  return await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    return store.getState().connected;
  });
}

test.describe('Notes View - Connection State Stability', () => {
  test.use({ viewport: { width: 1024, height: 768 } });

  test.beforeEach(async ({ page }) => {
    await page.goto('http://localhost:5173');
    await setupTestMode(page);
  });

  test('navigating to Notes and back preserves connection state', async ({ page }) => {
    // Verify we start connected
    expect(await getConnectionState(page)).toBe(true);

    // Connection banner should NOT be visible when connected
    const banner = page.locator('[data-testid="connection-banner"]');
    await expect(banner).not.toBeVisible();

    // Navigate to Notes view
    const notesTab = page.getByRole('button', { name: /notes/i });
    await notesTab.click();
    await page.waitForSelector('[data-view="notes"]', { state: 'visible' });

    // Verify still connected while on Notes view
    expect(await getConnectionState(page)).toBe(true);
    await expect(banner).not.toBeVisible();

    // Navigate back to Timeline (default view)
    const timelineTab = page.getByRole('button', { name: /timeline/i });
    await timelineTab.click();
    await page.waitForSelector('[data-view="timeline"]', { state: 'visible' });

    // CRITICAL: Connection state should still be true after leaving Notes view
    // Bug: NotesView's second connection cleanup would set connected=false
    expect(await getConnectionState(page)).toBe(true);
    await expect(banner).not.toBeVisible();
  });

  test('multiple Notes view visits do not cause connection state oscillation', async ({ page }) => {
    const notesTab = page.getByRole('button', { name: /notes/i });
    const timelineTab = page.getByRole('button', { name: /timeline/i });
    const banner = page.locator('[data-testid="connection-banner"]');

    // Track all state changes during navigation
    const stateChanges: boolean[] = [await getConnectionState(page)];

    // Visit Notes and back multiple times
    for (let i = 0; i < 3; i++) {
      await notesTab.click();
      await page.waitForSelector('[data-view="notes"]', { state: 'visible' });
      stateChanges.push(await getConnectionState(page));

      await timelineTab.click();
      await page.waitForSelector('[data-view="timeline"]', { state: 'visible' });
      stateChanges.push(await getConnectionState(page));
    }

    // All states should be true (no oscillation between connected/disconnected)
    expect(stateChanges.every((state) => state === true)).toBe(true);

    // Banner should never have appeared
    await expect(banner).not.toBeVisible();
  });

  test('rapid Notes navigation does not cause state corruption', async ({ page }) => {
    const notesTab = page.getByRole('button', { name: /notes/i });
    const timelineTab = page.getByRole('button', { name: /timeline/i });

    // Rapidly navigate between views without waiting
    for (let i = 0; i < 5; i++) {
      await notesTab.click();
      await timelineTab.click();
    }

    // Wait for all navigation to settle
    await page.waitForSelector('[data-view="timeline"]', { state: 'visible' });
    await page.waitForTimeout(100);

    // Connection state should still be true
    expect(await getConnectionState(page)).toBe(true);

    // Banner should not be visible
    const banner = page.locator('[data-testid="connection-banner"]');
    await expect(banner).not.toBeVisible();
  });

});
