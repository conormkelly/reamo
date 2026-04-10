/**
 * Transport command and state event tests.
 *
 * Transport commands (play, stop, pause, etc.) are fire-and-forget —
 * the server does not send a response. We verify via transport state events.
 *
 * REAPER must be running with the extension loaded.
 */

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { ReamoClient } from '../helpers/client.js';

interface TransportPayload {
  playState: number;
  position: number;
  bpm: number;
  timeSignature: { numerator: number; denominator: number };
}

describe('Transport', () => {
  const client = new ReamoClient();

  beforeAll(async () => {
    await client.connect();
    // Ensure transport is stopped before tests
    client.sendFireAndForget('transport/stop');
    await client.waitForEvent<TransportPayload>('transport', {
      predicate: (p) => p.playState === 0,
      timeout: 2000,
    });
  });

  afterAll(() => {
    client.sendFireAndForget('transport/stop');
    setTimeout(() => client.close(), 200);
  });

  it('receives transport state with expected fields', async () => {
    const transport = await client.waitForEvent<TransportPayload>('transport', { timeout: 3000 });

    expect(transport).toHaveProperty('playState');
    expect(transport).toHaveProperty('position');
    expect(transport).toHaveProperty('bpm');
    expect(transport).toHaveProperty('timeSignature');
    expect(transport.timeSignature).toHaveProperty('numerator');
    expect(transport.timeSignature).toHaveProperty('denominator');
    expect(typeof transport.playState).toBe('number');
    expect(typeof transport.bpm).toBe('number');
    expect(transport.bpm).toBeGreaterThan(0);
  });

  it('can start and stop playback', async () => {
    client.sendFireAndForget('transport/play');

    const playing = await client.waitForEvent<TransportPayload>('transport', {
      predicate: (p) => p.playState === 1,
      timeout: 2000,
    });
    expect(playing.playState).toBe(1);

    client.sendFireAndForget('transport/stop');

    const stopped = await client.waitForEvent<TransportPayload>('transport', {
      predicate: (p) => p.playState === 0,
      timeout: 2000,
    });
    expect(stopped.playState).toBe(0);
  });

  it('can seek to a position', async () => {
    client.sendFireAndForget('transport/seek', { position: 5.0 });

    const transport = await client.waitForEvent<TransportPayload>('transport', {
      predicate: (p) => Math.abs(p.position - 5.0) < 0.1,
      timeout: 2000,
    });
    expect(transport.position).toBeCloseTo(5.0, 0);

    // Seek back to start
    client.sendFireAndForget('transport/goStart');
    await client.waitForEvent<TransportPayload>('transport', {
      predicate: (p) => p.position < 0.1,
      timeout: 2000,
    });
  });
});
