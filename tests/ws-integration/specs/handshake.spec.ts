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
    const pongPromise = client.waitForEvent('__raw_pong', { timeout: 3000 }).catch(() => null);

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
    expect((clockResponse as Record<string, unknown>).t0).toBe(t0);
    expect((clockResponse as Record<string, unknown>).t1).toBeTypeOf('number');
    expect((clockResponse as Record<string, unknown>).t2).toBeTypeOf('number');
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
    // Register listeners BEFORE connecting to avoid missing snapshot events
    let t1Received = false;
    let t2Received = false;
    client1.onMessage((msg) => {
      if (msg.type === 'event' && (msg as any).event === 'transport') t1Received = true;
    });
    client2.onMessage((msg) => {
      if (msg.type === 'event' && (msg as any).event === 'transport') t2Received = true;
    });

    const hello1 = await client1.connect();
    const hello2 = await client2.connect();

    expect(hello1.extensionVersion).toBe(hello2.extensionVersion);

    // Wait briefly for transport broadcasts to arrive
    await new Promise((r) => setTimeout(r, 1000));

    expect(t1Received).toBe(true);
    expect(t2Received).toBe(true);
  });
});
