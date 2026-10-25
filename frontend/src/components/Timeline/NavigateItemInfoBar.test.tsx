/**
 * NavigateItemInfoBar - item notes editing
 *
 * Saving an item's notes replaces them in REAPER, so the sheet offers an
 * editor only over notes REAPER actually sent.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { useReaperStore } from '../../store';
import type { WSItem } from '../../core/WebSocketTypes';

vi.hoisted(() => vi.resetModules());

const sendCommand = vi.fn();
const sendAsync = vi.fn();
vi.mock('../ReaperProvider', () => ({
  useReaper: () => ({ sendCommand, sendAsync, connected: true }),
}));

const { NavigateItemInfoBar } = await import('./NavigateItemInfoBar');

const ITEM: WSItem = {
  guid: '{VOX-TAKE}',
  trackIdx: 1,
  itemIdx: 0,
  position: 0,
  length: 10,
  color: 0,
  locked: false,
  selected: true,
  activeTakeIdx: 0,
  hasNotes: true,
  takeCount: 1,
  activeTakeName: 'Vox',
  activeTakeGuid: '{TAKE}',
  activeTakeIsMidi: false,
  activeTakeColor: null,
};

function openSheet() {
  render(<NavigateItemInfoBar />);
  fireEvent.click(screen.getByTitle('More options'));
}

describe('NavigateItemInfoBar notes', () => {
  beforeEach(() => {
    sendCommand.mockReset();
    sendAsync.mockReset();
    useReaperStore.setState({ items: [ITEM], bpm: 120, itemSelectionModeActive: true });
  });

  it('offers no editor over notes that failed to load, so saving cannot erase them', async () => {
    sendAsync.mockRejectedValue(new Error('timeout'));
    openSheet();
    const failed = await screen.findByText("Couldn't load notes. Tap to try again.");
    expect(screen.queryByText('Add notes...')).toBeNull();
    expect(screen.queryByRole('textbox')).toBeNull();

    sendAsync.mockResolvedValue({ success: true, payload: { notes: 'double the chorus' } });
    fireEvent.click(failed);
    expect(await screen.findByText('double the chorus')).toBeTruthy();
  });

  it('edits and saves the notes REAPER sent, naming the item by GUID', async () => {
    sendAsync.mockResolvedValue({ success: true, payload: { notes: 'double the chorus' } });
    openSheet();
    fireEvent.click(await screen.findByText('double the chorus'));
    const editor = screen.getByRole('textbox') as HTMLTextAreaElement;
    expect(editor.value).toBe('double the chorus');
    fireEvent.change(editor, { target: { value: 'double the chorus, then cut' } });
    fireEvent.click(screen.getByText('Save'));

    expect(sendAsync).toHaveBeenCalledWith('item/getNotes', { itemGuid: '{VOX-TAKE}' });
    expect(sendCommand).toHaveBeenCalledWith({
      command: 'item/setNotes',
      params: { itemGuid: '{VOX-TAKE}', notes: 'double the chorus, then cut' },
    });
    await waitFor(() => expect(screen.getByText('double the chorus, then cut')).toBeTruthy());
  });

});

describe('NavigateItemInfoBar move', () => {
  // A project whose tempo halves at bar 5 (8 s): bar 6 is at 12 s, and bars
  // from 5 on are 4 s long. The item sits at bar 5.
  function fakeReaper(command: string, params?: Record<string, unknown>) {
    const p = params as Record<string, number>;
    switch (command) {
      case 'item/getNotes':
        return Promise.resolve({ success: true, payload: { notes: '' } });
      case 'tempo/timeToBeats':
        return Promise.resolve({ success: true, payload: { bars: p.time === 8 ? '5.1.00' : '?' } });
      case 'tempo/barsToTime':
        return Promise.resolve({ success: true, payload: { time: p.bar === 6 && p.beat === 1 ? 12 : -1 } });
      case 'tempo/getBarDuration':
        return Promise.resolve({ success: true, payload: { duration: p.time >= 8 ? 4 : 2, durationBeats: 4 } });
      default:
        return Promise.reject(new Error(command));
    }
  }

  beforeEach(() => {
    sendCommand.mockReset();
    sendAsync.mockReset();
    sendAsync.mockImplementation(fakeReaper);
    useReaperStore.setState({ items: [{ ...ITEM, position: 8 }], bpm: 120, itemSelectionModeActive: true });
  });

  async function openMove() {
    openSheet();
    fireEvent.click(screen.getByText('Position'));
    return (await screen.findByDisplayValue('5.1')) as HTMLInputElement;
  }

  it('moves the item to the time REAPER gives for a bar, across a tempo change', async () => {
    const input = await openMove();
    fireEvent.change(input, { target: { value: '6.1' } });
    fireEvent.click(screen.getByText('Set Position'));
    await waitFor(() =>
      expect(sendCommand).toHaveBeenCalledWith({ command: 'item/moveByGuid', params: { guid: '{VOX-TAKE}', position: 12 } })
    );
  });

  it('nudges by the length of the bar the item is in, not a bar at the playhead tempo', async () => {
    await openMove();
    fireEvent.click(screen.getByText('+1 bar'));
    await waitFor(() =>
      expect(sendCommand).toHaveBeenCalledWith({ command: 'item/moveByGuid', params: { guid: '{VOX-TAKE}', position: 12 } })
    );
    fireEvent.click(screen.getByText('-1 bar'));
    await waitFor(() =>
      expect(sendCommand).toHaveBeenCalledWith({ command: 'item/moveByGuid', params: { guid: '{VOX-TAKE}', position: 6 } })
    );
  });
});

