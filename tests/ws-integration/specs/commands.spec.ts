/**
 * Command/response correlation and error handling tests.
 *
 * Note: Many simple commands (transport/play, transport/stop, etc.) are
 * fire-and-forget — the server does NOT send a response. Only commands
 * that explicitly call response.success() or response.err() return responses.
 */

import { describe, it, expect, beforeAll, afterAll, afterEach } from 'vitest';
import { ReamoClient } from '../helpers/client.js';

describe('Command correlation', () => {
  const client = new ReamoClient();

  beforeAll(async () => {
    await client.connect();
  });

  afterAll(() => {
    client.close();
  });

  it('returns error for unknown commands', async () => {
    const resp = await client.sendCommand('nonexistent/command');
    expect(resp.type).toBe('response');
    expect(resp.success).toBe(false);
    expect(resp.error).toBeDefined();
    expect(resp.error!.code).toBe('UNKNOWN_COMMAND');
  });

  it('returns success for track/subscribe', async () => {
    const resp = await client.sendCommand('track/subscribe', {
      range: { start: 0, end: 4 },
    });
    expect(resp.type).toBe('response');
    expect(resp.success).toBe(true);

    // Clean up
    await client.sendCommand('track/unsubscribe');
  });

  it('correlates responses to the correct command via id', async () => {
    const [resp1, resp2] = await Promise.all([
      client.sendCommand('track/subscribe', { range: { start: 0, end: 4 } }),
      client.sendCommand('nonexistent/command2'),
    ]);

    expect(resp1.id).toBeDefined();
    expect(resp2.id).toBeDefined();
    expect(resp1.id).not.toBe(resp2.id);

    expect(resp1.success).toBe(true);
    expect(resp2.success).toBe(false);

    await client.sendCommand('track/unsubscribe');
  });
});

describe('Initial snapshot events', () => {
  // Use a fresh client per test so we catch the initial snapshot events
  let client: ReamoClient;

  afterEach(() => {
    client?.close();
  });

  it('receives project metadata on connect', async () => {
    client = new ReamoClient();

    // Register listener BEFORE connecting so we don't miss the snapshot
    const projectPromise = new Promise<Record<string, unknown>>((resolve) => {
      client.onMessage((msg) => {
        if (msg.type === 'event' && (msg as any).event === 'project') {
          resolve((msg as any).payload);
        }
      });
    });

    await client.connect();

    const project = await Promise.race([
      projectPromise,
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error('timeout')), 5000)),
    ]);

    expect(project).toHaveProperty('repeat');
    expect(project).toHaveProperty('metronome');
    expect(project).toHaveProperty('projectName');
  });

  it('receives markers on connect', async () => {
    client = new ReamoClient();

    const markersPromise = new Promise<unknown>((resolve) => {
      client.onMessage((msg) => {
        if (msg.type === 'event' && (msg as any).event === 'markers') {
          resolve((msg as any).payload);
        }
      });
    });

    await client.connect();

    const markers = await Promise.race([
      markersPromise,
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error('timeout')), 5000)),
    ]);

    expect(markers).toBeDefined();
  });

  it('receives transport state on connect', async () => {
    client = new ReamoClient();

    const transportPromise = new Promise<Record<string, unknown>>((resolve) => {
      client.onMessage((msg) => {
        if (msg.type === 'event' && (msg as any).event === 'transport') {
          resolve((msg as any).payload);
        }
      });
    });

    await client.connect();

    const transport = await Promise.race([
      transportPromise,
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error('timeout')), 5000)),
    ]);

    expect(transport).toHaveProperty('playState');
    expect(transport).toHaveProperty('bpm');
  });
});
