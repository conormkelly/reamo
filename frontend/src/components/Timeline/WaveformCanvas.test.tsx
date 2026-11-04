/**
 * WaveformCanvas placement: a take's tiles are drawn where its item is now.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, cleanup } from '@testing-library/react';
import type { WSItem } from '../../core/WebSocketTypes';

vi.hoisted(() => vi.resetModules());

// Every tile has a bitmap ready, so each one is blitted with drawImage.
vi.mock('../../core/TileBitmapCache', () => ({
  TILE_RENDER_WIDTH: 256,
  tileBitmapCache: {
    get: () => ({ height: 80 }),
    getOrRender: () => Promise.resolve(),
  },
}));

const { WaveformCanvas } = await import('./WaveformCanvas');
const { useReaperStore } = await import('../../store');

const TAKE = '{TAKE-ON-THE-ITEM}';

function item(overrides: Partial<WSItem>): WSItem {
  return {
    guid: '{ITEM}',
    trackIdx: 1,
    itemIdx: 0,
    position: 0,
    length: 1,
    color: 0,
    locked: false,
    selected: false,
    activeTakeIdx: 0,
    hasNotes: false,
    takeCount: 1,
    activeTakeName: 'take',
    activeTakeGuid: TAKE,
    activeTakeIsMidi: false,
    activeTakeColor: null,
    ...overrides,
  };
}

/** Destination x and width of each drawImage call. */
let blits: Array<{ x: number; width: number }>;

beforeEach(() => {
  blits = [];
  const ctx = new Proxy(
    {
      drawImage: (...args: number[]) => blits.push({ x: args[5], width: args[7] }),
    } as Record<string, unknown>,
    { get: (target, prop) => (prop in target ? target[prop as string] : () => {}), set: () => true }
  );
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(ctx as unknown as CanvasRenderingContext2D);
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('WaveformCanvas', () => {
  it("draws a take's tiles at its item's current position, not the position the tiles were sent with", () => {
    // The tile was sent while the item was at 2 s; the item is at 4 s now.
    useReaperStore.setState({ tileCache: new Map(), tilesByTake: new Map() });
    useReaperStore.getState().handlePeaksEvent({
      tiles: [
        {
          takeGuid: TAKE,
          epoch: 1,
          lod: 6,
          tileIndex: 0,
          itemPosition: 2,
          startTime: 0,
          endTime: 1,
          channels: 1,
          peaks: [[-0.5, 0.5]],
        },
      ],
    });

    // 10 s across 1000 px: the item at 4..5 s covers x 400..500.
    render(
      <WaveformCanvas
        trackIdx={1}
        width={1000}
        height={100}
        viewportStart={0}
        viewportEnd={10}
        items={[item({ position: 4, length: 1 })]}
      />
    );

    expect(blits).toEqual([{ x: 400, width: 100 }]);
  });
});
