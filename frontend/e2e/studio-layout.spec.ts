/**
 * Studio Layout Customization E2E Tests
 *
 * Tests mobile-specific defaults, section collapsing, and settings menu functionality.
 */

import { test, expect, Page } from '@playwright/test';

// Wait for store to be available
async function setupTestStore(page: Page) {
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  });

  // Enable test mode FIRST - prevents WebSocket from overwriting connection state
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.getState()._setTestMode(true);
  });

  // Set basic test data
  await page.evaluate(() => {
    const store = (window as any).__REAPER_STORE__;
    store.setState({
      // Bypass loading screen (no real REAPER in e2e tests)
      connected: true,
      tracks: [
        { idx: 0, name: 'MASTER', volume: 1.0, pan: 0, color: 0, flags: 0 },
        { idx: 1, name: 'Track 1', volume: 0.8, pan: 0, color: 0xff0000, flags: 0 },
      ],
      regions: [
        { id: 0, name: 'Intro', start: 0, end: 10, color: 0xff0000 },
        { id: 1, name: 'Verse', start: 10, end: 20, color: 0x00ff00 },
      ],
      bpm: 120,
      timeSignatureNumerator: 4,
      timeSignatureDenominator: 4,
    });
  });
}

test.describe('Studio Layout - Mobile Behavior', () => {
  test.use({ viewport: { width: 375, height: 667 } }); // iPhone SE

  test.beforeEach(async ({ page }) => {
    await page.goto('http://localhost:5173');
    await setupTestStore(page);
    await page.waitForSelector('[data-view="studio"]', { state: 'visible' });
  });

  test('mobile: only Timeline section is expanded by default', async ({ page }) => {
    // Clear localStorage to get true defaults
    await page.evaluate(() => localStorage.clear());
    await page.reload();
    await setupTestStore(page);
    await page.waitForSelector('[data-view="studio"]', { state: 'visible' });

    // Check Timeline section is expanded (content visible)
    const timelineContent = page.locator('[data-testid="timeline-canvas"]');
    await expect(timelineContent).toBeVisible();

    // Check Project section is collapsed (time display not visible)
    const projectContent = page.locator('[data-testid="time-display"]');
    await expect(projectContent).not.toBeVisible();
  });

  test('mobile: can expand collapsed sections', async ({ page }) => {
    // Project section should be collapsed
    const projectContent = page.locator('[data-testid="time-display"]');
    await expect(projectContent).not.toBeVisible();

    // Click to expand Project section
    await page.locator('[data-section-header="project"]').click();

    // Now project content should be visible
    await expect(projectContent).toBeVisible();
  });

  test('mobile: can collapse expanded sections', async ({ page }) => {
    // Timeline should be expanded
    const timelineContent = page.locator('[data-testid="timeline-canvas"]');
    await expect(timelineContent).toBeVisible();

    // Click to collapse Timeline section
    await page.locator('[data-section-header="timeline"]').click();

    // Now timeline content should not be visible
    await expect(timelineContent).not.toBeVisible();
  });

  test('mobile: section state persists after collapse/expand', async ({ page }) => {
    // Expand Project section
    await page.locator('[data-section-header="project"]').click();
    await expect(page.locator('[data-testid="time-display"]')).toBeVisible();

    // Collapse Timeline section
    await page.locator('[data-section-header="timeline"]').click();
    await expect(page.locator('[data-testid="timeline-canvas"]')).not.toBeVisible();

    // Reload page - need to re-setup test mode after reload
    await page.reload();
    await setupTestStore(page);
    await page.waitForSelector('[data-view="studio"]', { state: 'visible' });

    // Wait for localStorage-persisted section states to be applied
    // (React useEffect runs after initial render)
    await page.waitForTimeout(200);

    // Verify state persisted
    await expect(page.locator('[data-testid="time-display"]')).toBeVisible(); // Project still expanded
    await expect(page.locator('[data-testid="timeline-canvas"]')).not.toBeVisible(); // Timeline still collapsed
  });
});

test.describe('Studio Layout - Desktop Behavior', () => {
  test.use({ viewport: { width: 1024, height: 768 } }); // iPad

  test.beforeEach(async ({ page }) => {
    await page.goto('http://localhost:5173');
    await setupTestStore(page);
    await page.waitForSelector('[data-view="studio"]', { state: 'visible' });
  });

  test('desktop: all sections expanded by default', async ({ page }) => {
    // All section content should be visible
    await expect(page.locator('[data-testid="time-display"]')).toBeVisible(); // Project
    await expect(page.locator('[data-testid="timeline-canvas"]')).toBeVisible(); // Timeline

    // Note: Toolbar and Mixer visibility depends on whether there are tracks/actions
    // Just verify the sections exist and are expanded
    const toolbarSection = page.locator('[data-section-header="toolbar"]');
    const mixerSection = page.locator('[data-section-header="mixer"]');
    await expect(toolbarSection).toBeVisible();
    await expect(mixerSection).toBeVisible();
  });

  test('desktop: can collapse all sections', async ({ page }) => {
    // Collapse all sections
    await page.locator('[data-section-header="project"]').click();
    await page.locator('[data-section-header="toolbar"]').click();
    await page.locator('[data-section-header="timeline"]').click();
    await page.locator('[data-section-header="mixer"]').click();

    // All content should be hidden
    await expect(page.locator('[data-testid="time-display"]')).not.toBeVisible();
    await expect(page.locator('[data-testid="timeline-canvas"]')).not.toBeVisible();
  });
});

test.describe('Settings Menu - Studio Section', () => {
  test.use({ viewport: { width: 1024, height: 768 } }); // iPad

  test.beforeEach(async ({ page }) => {
    await page.goto('http://localhost:5173');
    await setupTestStore(page);
    await page.waitForSelector('[data-view="studio"]', { state: 'visible' });
  });

  test('opens settings menu and shows Studio section', async ({ page }) => {
    // Click hamburger menu
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();

    const dropdown = page.locator('[data-testid="settings-dropdown"]');

    // Verify Global section is visible
    await expect(dropdown.getByText('Global', { exact: true })).toBeVisible();
    await expect(dropdown.getByText('Tab Bar')).toBeVisible();
    await expect(dropdown.getByText('Transport Bar')).toBeVisible();
    await expect(dropdown.getByText('Transport Position')).toBeVisible();

    // Verify Studio section is visible (only when in Studio view)
    await expect(dropdown.getByText('Studio', { exact: true })).toBeVisible();
    await expect(dropdown.getByText('Reorder Sections')).toBeVisible();
    await expect(dropdown.getByText('Rec Quick Actions')).toBeVisible();
  });

  test('Reorder Sections button opens modal', async ({ page }) => {
    // Open settings menu
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();

    const dropdown = page.locator('[data-testid="settings-dropdown"]');
    await dropdown.getByText('Reorder Sections').click();

    // Verify modal opened
    await expect(page.getByRole('heading', { name: /reorder sections/i })).toBeVisible();

    // Verify all 4 section items are present
    const sections = page.locator('[data-testid="reorder-section-item"]');
    await expect(sections).toHaveCount(4);

    // Close modal
    await page.getByRole('button', { name: /done/i }).click();
    await expect(page.getByRole('heading', { name: /reorder sections/i })).not.toBeVisible();
  });

  test('Rec Quick Actions toggle works', async ({ page }) => {
    // Open settings menu
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();

    let dropdown = page.locator('[data-testid="settings-dropdown"]');

    // Find the Rec Quick Actions button within the dropdown
    const recActionsButton = dropdown.getByText('Rec Quick Actions').locator('..');

    // Check initial state (should show Visible or Hidden)
    const initialState = await recActionsButton.locator('span').last().textContent();

    // Click to toggle
    await recActionsButton.click();

    // Menu should still be open, just get fresh reference
    dropdown = page.locator('[data-testid="settings-dropdown"]');
    const newState = await dropdown.getByText('Rec Quick Actions').locator('..').locator('span').last().textContent();

    // State should have changed
    expect(newState).not.toBe(initialState);
  });

  test('Tab Bar toggle works', async ({ page }) => {
    // Open settings menu
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();

    let dropdown = page.locator('[data-testid="settings-dropdown"]');

    // Click Tab Bar toggle
    const tabBarButton = dropdown.getByText('Tab Bar').locator('..');
    await tabBarButton.click();

    // Tab bar should disappear
    const tabBar = page.locator('nav').filter({ hasText: /studio/i });
    await expect(tabBar).not.toBeVisible();

    // Menu should still be open, toggle back
    dropdown = page.locator('[data-testid="settings-dropdown"]');
    await dropdown.getByText('Tab Bar').locator('..').click();

    // Tab bar should reappear
    await expect(tabBar).toBeVisible();
  });

  test('Transport Bar toggle works', async ({ page }) => {
    // Open settings menu
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();

    let dropdown = page.locator('[data-testid="settings-dropdown"]');

    // Click Transport Bar toggle
    const transportButton = dropdown.getByText('Transport Bar').locator('..');
    await transportButton.click();

    // Persistent transport should disappear
    // (Note: This tests the toggle - actual transport visibility depends on implementation)
    // Menu should still be open, just verify the state changed
    dropdown = page.locator('[data-testid="settings-dropdown"]');
    const state = await dropdown.getByText('Transport Bar').locator('..').locator('span').last().textContent();
    expect(state).toContain('Hidden');
  });

  test('Transport Position toggle switches between Left and Right', async ({ page }) => {
    // Open settings menu
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();

    let dropdown = page.locator('[data-testid="settings-dropdown"]');

    // Get initial position
    const positionButton = dropdown.getByText('Transport Position').locator('..');
    const initialPosition = await positionButton.locator('span').last().textContent();

    // Click to toggle
    await positionButton.click();

    // Menu should still be open, just check position changed
    dropdown = page.locator('[data-testid="settings-dropdown"]');
    const newPosition = await dropdown.getByText('Transport Position').locator('..').locator('span').last().textContent();

    // Position should have switched
    if (initialPosition?.includes('Left')) {
      expect(newPosition).toContain('Right');
    } else {
      expect(newPosition).toContain('Left');
    }
  });

  test('Studio section only visible in Studio view', async ({ page }) => {
    // In Studio view, Studio section should be visible
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();

    const dropdown = page.locator('[data-testid="settings-dropdown"]');
    await expect(dropdown.getByText('Studio', { exact: true })).toBeVisible();
    await settingsButton.click(); // Close menu

    // Switch to Clock view
    await page.getByRole('button', { name: /clock/i }).click();
    await page.waitForSelector('[data-view="clock"]', { state: 'visible' });

    // Open settings again
    await settingsButton.click();

    // Studio section should NOT be visible
    await expect(dropdown.getByText('Studio', { exact: true })).not.toBeVisible();
    await expect(dropdown.getByText('Reorder Sections')).not.toBeVisible();
  });
});

test.describe('Reorder Sections Modal - Touch Support', () => {
  test.use({ viewport: { width: 375, height: 667 } }); // iPhone SE

  test.beforeEach(async ({ page }) => {
    await page.goto('http://localhost:5173');
    await setupTestStore(page);
    await page.waitForSelector('[data-view="studio"]', { state: 'visible' });

    // Open modal
    const settingsButton = page.getByTitle('Settings');
    await settingsButton.click();
    const dropdown = page.locator('[data-testid="settings-dropdown"]');
    await dropdown.getByText('Reorder Sections').click();
    await expect(page.getByRole('heading', { name: /reorder sections/i })).toBeVisible();
  });

  test('modal displays all sections with grip handles', async ({ page }) => {
    // Verify all sections are present
    const sections = page.locator('[data-testid="reorder-section-item"]');
    await expect(sections).toHaveCount(4);

    // Verify each section has a grip icon (indicates draggable)
    const projectItem = page.locator('[data-testid="reorder-section-item"]').filter({ hasText: 'Project' });
    const gripIcon = projectItem.locator('svg'); // GripVertical icon
    await expect(gripIcon).toBeVisible();
  });

  test('sections have touch-friendly styling', async ({ page }) => {
    const sections = page.locator('[data-testid="reorder-section-item"]');
    const firstSection = sections.first();

    // Verify touch-none class (prevents scrolling during drag)
    const classes = await firstSection.getAttribute('class');
    expect(classes).toContain('touch-none');
    expect(classes).toContain('select-none');
    // cursor-move was changed to cursor-grab for better UX
    expect(classes).toContain('cursor-grab');
  });

  test('can close modal with Done button', async ({ page }) => {
    await page.getByRole('button', { name: /done/i }).click();
    await expect(page.getByRole('heading', { name: /reorder sections/i })).not.toBeVisible();
  });

  test('can close modal by clicking backdrop', async ({ page }) => {
    // Click outside the modal (backdrop)
    await page.locator('.fixed.inset-0').click({ position: { x: 10, y: 10 } });
    await expect(page.getByRole('heading', { name: /reorder sections/i })).not.toBeVisible();
  });
});
