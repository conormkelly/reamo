/**
 * useBarPositions Tests
 *
 * Bar.beat positions typed or shown on the phone are converted by REAPER,
 * through the project's tempo map and time signatures, never with the
 * tempo at the playhead: that is only right in a project with one tempo.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { renderHook } from '@testing-library/react';

vi.hoisted(() => vi.resetModules());

const sendAsync = vi.fn();
vi.mock('../components/ReaperProvider', () => ({
  useReaper: () => ({ sendAsync }),
}));

const { useBarPositions, parseBarPosition } = await import('./useBarPositions');

describe('parseBarPosition', () => {
  it('reads bar, bar.beat and bar.beat.ticks as on the ruler', () => {
    expect(parseBarPosition('17')).toEqual({ bar: 17, beat: 1, ticks: 0 });
    expect(parseBarPosition(' 17.3 ')).toEqual({ bar: 17, beat: 3, ticks: 0 });
    expect(parseBarPosition('17.3.50')).toEqual({ bar: 17, beat: 3, ticks: 50 });
    expect(parseBarPosition('-4.1')).toEqual({ bar: -4, beat: 1, ticks: 0 });
  });

  it('refuses what is not a position', () => {
    for (const text of ['', 'abc', '5.0', '5.2.100', '5.2.-1', '5.x', '5.2.3.4', '1:30']) {
      expect(parseBarPosition(text), text).toBeNull();
    }
  });
});

describe('useBarPositions', () => {
  beforeEach(() => sendAsync.mockReset());

  it('asks REAPER for the time of a bar.beat position', async () => {
    sendAsync.mockResolvedValue({ success: true, payload: { time: 41.25 } });
    const { result } = renderHook(() => useBarPositions());
    expect(await result.current.barsToSeconds('17.3.50')).toBe(41.25);
    expect(sendAsync).toHaveBeenCalledWith('tempo/barsToTime', { bar: 17, beat: 3, ticks: 50 });
  });

  it('gives null, not a guess, when REAPER cannot place the position', async () => {
    const { result } = renderHook(() => useBarPositions());
    sendAsync.mockResolvedValueOnce({ success: false, error: { code: 'INVALID_BAR' } });
    expect(await result.current.barsToSeconds('-99')).toBeNull();
    sendAsync.mockRejectedValueOnce(new Error('timeout'));
    expect(await result.current.barsToSeconds('5')).toBeNull();
    expect(await result.current.barsToSeconds('nonsense')).toBeNull();
  });

  it('asks REAPER for the ruler label of a time, without zero ticks', async () => {
    const { result } = renderHook(() => useBarPositions());
    sendAsync.mockResolvedValueOnce({ success: true, payload: { beats: 64, bars: '17.1.00' } });
    expect(await result.current.secondsToBars(41.25)).toBe('17.1');
    expect(sendAsync).toHaveBeenCalledWith('tempo/timeToBeats', { time: 41.25 });
    sendAsync.mockResolvedValueOnce({ success: true, payload: { beats: 65.5, bars: '17.2.50' } });
    expect(await result.current.secondsToBars(42)).toBe('17.2.50');
    sendAsync.mockRejectedValueOnce(new Error('timeout'));
    expect(await result.current.secondsToBars(1)).toBeNull();
  });

  it('asks REAPER how long the bar at a time is, and its beats', async () => {
    const { result } = renderHook(() => useBarPositions());
    sendAsync.mockResolvedValueOnce({ success: true, payload: { duration: 3, durationBeats: 6, bpm: 120 } });
    expect(await result.current.barLengthAt(10)).toEqual({ bar: 3, beat: 0.5 });
    expect(sendAsync).toHaveBeenCalledWith('tempo/getBarDuration', { time: 10 });
    sendAsync.mockRejectedValueOnce(new Error('timeout'));
    expect(await result.current.barLengthAt(10)).toBeNull();
  });
});
