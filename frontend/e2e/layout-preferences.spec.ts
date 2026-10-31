/**
 * Layout Preferences E2E Tests
 *
 * The settings-menu layout toggles (recording actions bar, pinned master,
 * add-track button, piano wheels) are saved to localStorage and must be read
 * back when the app starts, so a page reload keeps the user's choices.
 */

import { test, expect, Page } from '@playwright/test';

interface LayoutPrefs {
  showRecordingActions: boolean;
  pinMasterTrack: boolean;
  showAddTrackButton: boolean;
  showPianoWheels: boolean;
}

async function waitForStore(page: Page) {
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  });
}

async function readLayoutPrefs(page: Page): Promise<LayoutPrefs> {
  return page.evaluate(() => {
    const s = (window as any).__REAPER_STORE__.getState();
    return {
      showRecordingActions: s.showRecordingActions,
      pinMasterTrack: s.pinMasterTrack,
      showAddTrackButton: s.showAddTrackButton,
      showPianoWheels: s.showPianoWheels,
    };
  });
}

test.describe('Layout preferences', () => {
  test('layout toggles turned off keep their value across a page reload', async ({ page }) => {
    await page.goto('/');
    await waitForStore(page);

    // Every preference defaults to true, so false proves the stored value was read
    await page.evaluate(() => {
      const s = (window as any).__REAPER_STORE__.getState();
      s.setShowRecordingActions(false);
      s.setPinMasterTrack(false);
      s.setShowAddTrackButton(false);
      s.setShowPianoWheels(false);
    });

    // The setters saved the values, so a failure after reload is on the read side
    const saved = await page.evaluate(() => localStorage.getItem('reamo_studio_layout'));
    expect(JSON.parse(saved ?? 'null')).toEqual({
      showRecordingActions: false,
      pinMasterTrack: false,
      showAddTrackButton: false,
      showPianoWheels: false,
    });

    await page.reload();
    await waitForStore(page);

    await expect.poll(() => readLayoutPrefs(page), { timeout: 3000 }).toEqual({
      showRecordingActions: false,
      pinMasterTrack: false,
      showAddTrackButton: false,
      showPianoWheels: false,
    });
  });
});
