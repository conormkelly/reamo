/**
 * Hello handshake and connection lifecycle tests.
 */

import { describe, it, expect, afterEach } from 'vitest';
import { ReamoClient } from '../helpers/client.js';

describe('Handshake', () => {
  const client = new ReamoClient();

  afterEach(() => {
    client.close();
  });

  it('completes hello handshake and receives extension version', async () => {
    const hello = await client.connect();

    expect(hello.type).toBe('hello');
    expect(hello.protocolVersion).toBe(1);
    expect(hello.extensionVersion).toMatch(/^\d+\.\d+\.\d+/);
  });

  it('receives initial state events after handshake', async () => {
    await client.connect();

    // After hello, the server should start broadcasting state.
    // Transport is always broadcast — wait for at least one.
    const transport = await client.waitForEvent('transport', { timeout: 3000 });
    expect(transport).toBeDefined();
  });

  it('responds to ping with pong', async () => {
    await client.connect();

    const timestamp = Date.now();

    // Listen for raw pong (type: 'pong')
    let receivedPong = false;
    const remove = client.onMessage((msg) => {
      if ((msg as Record<string, unknown>).type === 'pong') {
        receivedPong = true;
      }
    });

    client.send({ type: 'ping', timestamp });

    // Give it a moment
    await new Promise((r) => setTimeout(r, 500));
    remove();

    expect(receivedPong).toBe(true);
  });

  it('supports clock sync', async () => {
    await client.connect();

    const t0 = Date.now();

    let clockResponse: Record<string, unknown> | null = null;
    const remove = client.onMessage((msg) => {
      if ((msg as Record<string, unknown>).type === 'clockSyncResponse') {
        clockResponse = msg as Record<string, unknown>;
      }
    });

    client.send({ type: 'clockSync', t0 });
    await new Promise((r) => setTimeout(r, 500));
    remove();

    expect(clockResponse).not.toBeNull();
    expect((clockResponse as unknown as Record<string, unknown>).t0).toBe(t0);
    expect((clockResponse as unknown as Record<string, unknown>).t1).toBeTypeOf('number');
    expect((clockResponse as unknown as Record<string, unknown>).t2).toBeTypeOf('number');
  });
});

describe('Multi-client', () => {
  const client1 = new ReamoClient();
  const client2 = new ReamoClient();

  afterEach(() => {
    client1.close();
    client2.close();
  });

  it('supports multiple concurrent connections', async () => {
    const hello1 = await client1.connect();
    const hello2 = await client2.connect();

    expect(hello1.extensionVersion).toBe(hello2.extensionVersion);

    // Both clients should independently receive events
    // Use collectEvents to verify both get broadcast data
    const [events1, events2] = await Promise.all([
      client1.collectEvents('transport', 1500),
      client2.collectEvents('transport', 1500),
    ]);

    expect(events1.length).toBeGreaterThan(0);
    expect(events2.length).toBeGreaterThan(0);
  });
});
