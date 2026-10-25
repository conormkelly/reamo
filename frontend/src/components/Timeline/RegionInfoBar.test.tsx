/**
 * RegionInfoBar - editing a region's start in bars
 *
 * REAPER converts the typed bar to a time through the project's tempo map.
 * When it can't answer, the region is left where it is: moving it by the
 * phone's own single-tempo guess would put it in the wrong place.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { useReaperStore } from '../../store';

vi.hoisted(() => vi.resetModules());

const sendCommand = vi.fn();
const sendCommandAsync = vi.fn();
vi.mock('../ReaperProvider', () => ({
  useReaper: () => ({ sendCommand, sendCommandAsync }),
}));

const { RegionInfoBar } = await import('./RegionInfoBar');

function editStart(value: string) {
  render(<RegionInfoBar />);
  fireEvent.click(screen.getByRole('button', { name: /^5\.1/ }));
  const input = screen.getByDisplayValue('5.1');
  fireEvent.change(input, { target: { value } });
  fireEvent.keyDown(input, { key: 'Enter' });
}

describe('RegionInfoBar start edit', () => {
  beforeEach(() => {
    sendCommand.mockReset();
    sendCommandAsync.mockReset();
    useReaperStore.setState({
      timelineMode: 'regions',
      selectedRegionIds: [1],
      bpm: 120,
      regions: [{ id: 1, name: 'Verse', start: 8, end: 20, startBars: '5.1.00', endBars: '8.1.00', lengthBars: '3.0.00' }],
    });
  });

  it('moves the start to the time REAPER gives for the bar', async () => {
    sendCommandAsync.mockResolvedValue({ success: true, payload: { time: 12 } });
    editStart('6.1');
    await waitFor(() =>
      expect(sendCommand).toHaveBeenCalledWith({ command: 'region/update', params: { id: 1, start: 12 } })
    );
  });

  it('leaves the region alone when REAPER does not answer', async () => {
    sendCommandAsync.mockRejectedValue(new Error('timeout'));
    editStart('6.1');
    await waitFor(() => expect(sendCommandAsync).toHaveBeenCalled());
    await new Promise((r) => setTimeout(r, 0));
    expect(sendCommand).not.toHaveBeenCalled();
  });
});
