import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { TransportAnimationEngine, type TransportAnimationState } from './TransportAnimationEngine';

/**
 * The engine runs on requestAnimationFrame and performance.now. Both are driven
 * by hand here so a test can model a hidden page: the browser stops running
 * animation frames while WebSocket messages keep arriving (desktop background
 * tab) or stop arriving altogether (iOS suspension).
 */
describe('TransportAnimationEngine', () => {
  let now = 0;
  let frameCallbacks = new Map<number, FrameRequestCallback>();
  let nextFrameId = 1;

  const PLAYING = 1;
  const TICK_INTERVAL_MS = 33;
  const FRAME_INTERVAL_MS = 16;

  function runFrame(): void {
    const callbacks = [...frameCallbacks.values()];
    frameCallbacks = new Map();
    callbacks.forEach((cb) => cb(now));
  }

  /** Advance time, delivering ticks from a server playing at 1x and optionally running frames. */
  function play(
    engine: TransportAnimationEngine,
    durationMs: number,
    serverPositionAt: (t: number) => number,
    { frames, ticks }: { frames: boolean; ticks: boolean }
  ): void {
    const end = now + durationMs;
    let nextTick = now + TICK_INTERVAL_MS;
    let nextFrame = now + FRAME_INTERVAL_MS;
    while (now < end) {
      const step = Math.min(
        ticks ? nextTick : Infinity,
        frames ? nextFrame : Infinity,
        end
      );
      now = step;
      if (ticks && now === nextTick) {
        engine.onTickUpdate(serverPositionAt(now), '1.1.00');
        nextTick += TICK_INTERVAL_MS;
      }
      if (frames && now === nextFrame) {
        runFrame();
        nextFrame += FRAME_INTERVAL_MS;
      }
    }
  }

  function startPlayback(engine: TransportAnimationEngine, position: number): void {
    engine.onServerUpdate({ position, positionBeats: '1.1.00', bpm: 120, playState: PLAYING });
  }

  beforeEach(() => {
    now = 1000;
    frameCallbacks = new Map();
    nextFrameId = 1;
    vi.spyOn(performance, 'now').mockImplementation(() => now);
    vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => {
      const id = nextFrameId++;
      frameCallbacks.set(id, cb);
      return id;
    });
    vi.stubGlobal('cancelAnimationFrame', (id: number) => {
      frameCallbacks.delete(id);
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it('tracks the server position during normal visible playback', () => {
    const engine = new TransportAnimationEngine();
    const startTime = now;
    const serverPositionAt = (t: number) => 10 + (t - startTime) / 1000;
    startPlayback(engine, 10);

    play(engine, 2000, serverPositionAt, { frames: true, ticks: true });

    expect(engine.getPosition()).toBeCloseTo(serverPositionAt(now), 1);
  });

  it('shows the server position on the first frame after returning from a background tab that kept receiving ticks', () => {
    const engine = new TransportAnimationEngine();
    const startTime = now;
    const serverPositionAt = (t: number) => 10 + (t - startTime) / 1000;
    const seen: number[] = [];
    engine.subscribe((state: TransportAnimationState) => seen.push(state.position));
    startPlayback(engine, 10);

    play(engine, 1000, serverPositionAt, { frames: true, ticks: true });
    // Hidden: no animation frames, ticks keep arriving over the open socket.
    play(engine, 10_000, serverPositionAt, { frames: false, ticks: true });
    seen.length = 0;
    // Visible again: the first frame renders without waiting for anything else.
    now += FRAME_INTERVAL_MS;
    runFrame();

    expect(seen).toHaveLength(1);
    expect(Math.abs(seen[0] - serverPositionAt(now))).toBeLessThan(0.005);
  });

  it('snaps to the server position on the first transport event after an iOS suspension that delivered no messages', () => {
    const engine = new TransportAnimationEngine();
    const startTime = now;
    const serverPositionAt = (t: number) => 10 + (t - startTime) / 1000;
    startPlayback(engine, 10);

    play(engine, 1000, serverPositionAt, { frames: true, ticks: true });
    // Suspended: neither frames nor messages for 10 s.
    now += 10_000;
    // Resumed: frames run again while the socket reconnects.
    play(engine, 300, serverPositionAt, { frames: true, ticks: false });
    // Reconnect delivers a full transport event, still playing.
    engine.onServerUpdate({
      position: serverPositionAt(now),
      positionBeats: '1.1.00',
      bpm: 120,
      playState: PLAYING,
    });

    expect(Math.abs(engine.getPosition() - serverPositionAt(now))).toBeLessThan(0.005);
  });
});
