/**
 * Actions View E2E Tests
 *
 * Sections taller than the screen must scroll, whichever way they're aligned.
 * Aligning with justify-content pushes the overflow out above the top of the
 * scroll range, where nothing can reach it.
 */

import { test, expect, Page } from '@playwright/test';

const SECTION_COUNT = 12;

async function setupTestStore(page: Page, align: 'top' | 'center' | 'bottom') {
  await page.waitForFunction(() => (window as any).__REAPER_STORE__ !== undefined, {
    timeout: 10000,
  });

  await page.evaluate(
    ({ count, align }) => {
      const store = (window as any).__REAPER_STORE__;
      store.getState()._setTestMode(true);
      store.setState({
        connected: true,
        trackSkeleton: [{ n: 'MASTER', g: 'master' }],
        totalTracks: 0,
        trackCount: 1,
        tracks: {},
        regions: [],
        markers: [],
        bpm: 120,
        actionsVerticalAlign: align,
      });
      for (let i = 1; i <= count; i++) {
        store.getState().addSection({ name: `Section ${i}` });
      }
    },
    { count: SECTION_COUNT, align },
  );
}

test.describe('Actions view on a phone', () => {
  test.use({ viewport: { width: 375, height: 548 } });

  for (const align of ['top', 'center', 'bottom'] as const) {
    test(`every section can be scrolled into view (${align} aligned)`, async ({ page }) => {
      await page.goto('/');
      await setupTestStore(page, align);
      await page.getByRole('button', { name: 'Actions', exact: true }).click();

      const scroller = page.locator('[data-view="actions"] .overflow-y-auto').first();
      const scrollerBox = (await scroller.boundingBox())!;

      for (const name of ['Section 1', `Section ${SECTION_COUNT}`]) {
        const header = page.getByText(name, { exact: true });
        await header.scrollIntoViewIfNeeded();
        const box = (await header.boundingBox())!;
        expect(box.y, `${name} top`).toBeGreaterThanOrEqual(scrollerBox.y);
        expect(box.y + box.height, `${name} bottom`).toBeLessThanOrEqual(scrollerBox.y + scrollerBox.height);
      }
    });
  }
});
