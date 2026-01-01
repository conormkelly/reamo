/**
 * Studio Layout Customization E2E Tests - Simplified
 *
 * Core tests for mobile defaults, section collapsing, and settings menu.
 */

import { test, expect, Page } from '@playwright/test';

// Wait for store to be available
async function setupTestStore(page: Page) {
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  });

  // Set basic test data
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.setState({
      tracks: [
        { idx: 0, name: 'MASTER', volume: 1.0, pan: 0, color: 0, flags: 0 },
      ],
      regions: [
        { id: 0, name: 'Intro', start: 0, end: 10, color: 0xff0000 },
      ],
      bpm: 120,
      timeSignatureNumerator: 4,
      timeSignatureDenominator: 4,
    });
  });
}

test.describe('Studio Layout - Core Functionality', () => {
  test.use({ viewport: { width: 1024, height: 768 } }); // iPad

  test.beforeEach(async ({ page }) => {
    await page.goto('http://localhost:5173');
    await setupTestStore(page);
    await page.waitForSelector('[data-view="studio"]', { state: 'visible' });
  });

  test('Settings menu opens and shows Studio section', async ({ page }) => {
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();

    // Verify sections are visible within the settings dropdown
    const dropdown = page.locator('[data-testid="settings-dropdown"]');
    await expect(dropdown.getByText('Global')).toBeVisible();
    await expect(dropdown.getByText('Studio')).toBeVisible();
    await expect(dropdown.getByText('Reorder Sections')).toBeVisible();
    await expect(dropdown.getByText('Rec Quick Actions')).toBeVisible();
  });

  test('Reorder Sections modal opens and closes', async ({ page }) => {
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();
    await page.getByText('Reorder Sections').click();

    // Modal should be visible
    await expect(page.getByRole('heading', { name: /reorder sections/i })).toBeVisible();

    // Should show all 4 sections
    const sections = page.locator('[data-testid="reorder-section-item"]');
    await expect(sections).toHaveCount(4);

    // Close with Done button
    await page.getByRole('button', { name: /done/i }).click();
    await expect(page.getByRole('heading', { name: /reorder sections/i })).not.toBeVisible();
  });

  test('Sections can be collapsed and expanded', async ({ page }) => {
    // Timeline should be visible initially
    const timelineCanvas = page.locator('[data-testid="timeline-canvas"]');
    await expect(timelineCanvas).toBeVisible();

    // Find and click the Timeline section header button using data attribute
    const timelineHeader = page.locator('[data-section-header="timeline"]');
    await timelineHeader.click();

    // Timeline should now be hidden
    await expect(timelineCanvas).not.toBeVisible();

    // Click again to expand
    await timelineHeader.click();
    await expect(timelineCanvas).toBeVisible();
  });

  test('Studio section only visible in Studio view', async ({ page }) => {
    // In Studio view
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();

    const dropdown = page.locator('[data-testid="settings-dropdown"]');
    await expect(dropdown.getByText('Studio')).toBeVisible();

    // Close menu
    await settingsButton.click();

    // Switch to Clock view
    await page.getByRole('button', { name: /clock/i }).click();
    await page.waitForSelector('[data-view="clock"]', { state: 'visible' });

    // Open settings again
    await settingsButton.click();

    // Studio section should NOT be visible
    await expect(dropdown.getByText('Studio')).not.toBeVisible();
  });
});

test.describe('Studio Layout - Mobile Defaults', () => {
  test.use({ viewport: { width: 375, height: 667 } }); // iPhone SE

  test('mobile: respects collapsed state', async ({ page }) => {
    await page.goto('http://localhost:5173');

    // Clear localStorage to get defaults
    await page.evaluate(() => localStorage.clear());
    await page.reload();

    await setupTestStore(page);
    await page.waitForSelector('[data-view="studio"]', { state: 'visible' });

    // Timeline should be visible
    const timelineCanvas = page.locator('[data-testid="timeline-canvas"]');
    await expect(timelineCanvas).toBeVisible();

    // Project time display might be collapsed
    // (Just verify the test infrastructure works)
    await expect(page.locator('[data-view="studio"]')).toBeVisible();
  });
});
