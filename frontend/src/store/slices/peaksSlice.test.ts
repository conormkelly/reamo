/**
 * Tests for peaksSlice: the tiles a take's waveform is drawn from.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { useReaperStore } from '../index';
import type { PeaksTile, MonoPeak, StereoPeak } from '../../core/WebSocketTypes';

function tile(epoch: number, tileIndex: number, channels: 1 | 2, takeGuid = '{TAKE}'): PeaksTile {
  const peaks: MonoPeak[] | StereoPeak[] =
    channels === 1
      ? [[-0.5, 0.5]]
      : [{ l: [-0.5, 0.5], r: [-0.25, 0.25] }];
  return {
    takeGuid,
    epoch,
    lod: 6,
    tileIndex,
    itemPosition: 1,
    startTime: tileIndex,
    endTime: tileIndex + 1,
    channels,
    peaks,
  };
}

/** The tiles WaveformCanvas draws for a take: every key in tilesByTake. */
function drawnTiles(takeGuid = '{TAKE}') {
  const { tilesByTake, tileCache } = useReaperStore.getState();
  return (tilesByTake.get(takeGuid) ?? []).map((key) => ({ key, tile: tileCache.get(key) }));
}

describe('peaksSlice', () => {
  beforeEach(() => {
    useReaperStore.getState().clearPeaksSubscription();
  });

  it('draws a take from the tiles of its latest epoch only, so a stereo-to-mono change leaves no stereo lanes behind', () => {
    const { handlePeaksEvent } = useReaperStore.getState();
    handlePeaksEvent({ tiles: [tile(100, 0, 2), tile(100, 1, 2)] });
    handlePeaksEvent({ tiles: [tile(200, 0, 1)] });

    const drawn = drawnTiles();
    expect(drawn.map((d) => d.key)).toEqual(['{TAKE}:200:6:0']);
    expect(drawn[0].tile?.channels).toBe(1);
    expect(useReaperStore.getState().tileCache.has('{TAKE}:100:6:0')).toBe(false);
    expect(useReaperStore.getState().tileCache.has('{TAKE}:100:6:1')).toBe(false);
  });

  it('keeps the tiles a take already has when more arrive under the same epoch', () => {
    const { handlePeaksEvent } = useReaperStore.getState();
    handlePeaksEvent({ tiles: [tile(100, 0, 2)] });
    handlePeaksEvent({ tiles: [tile(100, 1, 2)] });

    expect(drawnTiles().map((d) => d.key)).toEqual(['{TAKE}:100:6:0', '{TAKE}:100:6:1']);
  });

  it("leaves other takes' tiles alone when one take's epoch changes", () => {
    const { handlePeaksEvent } = useReaperStore.getState();
    handlePeaksEvent({ tiles: [tile(100, 0, 2), tile(7, 0, 2, '{OTHER}')] });
    handlePeaksEvent({ tiles: [tile(200, 0, 1)] });

    expect(drawnTiles('{OTHER}').map((d) => d.key)).toEqual(['{OTHER}:7:6:0']);
    expect(useReaperStore.getState().tileCache.has('{OTHER}:7:6:0')).toBe(true);
  });

  it('goes back to an earlier epoch when the take returns to it', () => {
    const { handlePeaksEvent } = useReaperStore.getState();
    handlePeaksEvent({ tiles: [tile(100, 0, 2)] });
    handlePeaksEvent({ tiles: [tile(200, 0, 1)] });
    handlePeaksEvent({ tiles: [tile(100, 0, 2)] });

    const drawn = drawnTiles();
    expect(drawn.map((d) => d.key)).toEqual(['{TAKE}:100:6:0']);
    expect(drawn[0].tile?.channels).toBe(2);
  });
});
