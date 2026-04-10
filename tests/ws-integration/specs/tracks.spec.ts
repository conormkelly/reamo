/**
 * Track subscription and state tests.
 *
 * REAPER must be running with at least one track in the project.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { ReamoClient } from '../helpers/client.js';

describe('Tracks', () => {
  const client = new ReamoClient();

  beforeAll(async () => {
    await client.connect();
  });

  afterAll(() => {
    client.close();
  });

  it('receives track skeleton broadcast', async () => {
    const skeleton = await client.waitForEvent('trackSkeleton', {
      timeout: 3000,
    });

    // trackSkeleton is broadcast as an object or array — just verify it arrives
    expect(skeleton).toBeDefined();
  });

  it('can subscribe to tracks and receive track data', async () => {
    const resp = await client.sendCommand('track/subscribe', {
      range: { start: 0, end: 9 },
      includeMaster: true,
    });
    expect(resp.success).toBe(true);

    // Should start receiving tracks events
    const tracks = await client.waitForEvent<Record<string, unknown>>('tracks', { timeout: 3000 });
    expect(tracks).toBeDefined();
    expect(typeof tracks).toBe('object');
  });

  it('can unsubscribe from tracks', async () => {
    const resp = await client.sendCommand('track/unsubscribe');
    expect(resp.success).toBe(true);

    // After unsubscribe, we should stop receiving tracks events.
    // Collect for a short window and expect few or none.
    const events = await client.collectEvents('tracks', 1500);

    // Might get one straggler, but shouldn't get a continuous stream
    expect(events.length).toBeLessThanOrEqual(1);
  });
});
