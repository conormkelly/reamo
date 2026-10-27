/**
 * TrackInfoBar - acting on the picked track
 *
 * Rename, duplicate and delete must reach the track the user picked, and an
 * armed delete must not carry over to a different track.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { useReaperStore } from '../../store';
import type { Track } from '../../core/types';

vi.hoisted(() => vi.resetModules());

const sendCommand = vi.fn();
vi.mock('../../hooks/useReaper', () => ({
  useReaper: () => ({ sendCommand, sendAsync: vi.fn(), connected: true }),
}));

const { TrackInfoBar } = await import('./TrackInfoBar');

function track(index: number, guid: string, name: string): Track {
  return {
    index, guid, name, flags: 0, volume: 1, pan: 0, lastMeterPeak: 0, lastMeterPos: 0, clipped: false,
    width: 1, panMode: 0, sendCount: 0, receiveCount: 0, hwOutCount: 0, fxCount: 0, color: 0,
  };
}

describe('TrackInfoBar', () => {
  beforeEach(() => {
    sendCommand.mockReset();
    useReaperStore.setState({ tracks: { 2: track(2, '{VOX}', 'Vox'), 3: track(3, '{BASS}', 'Bass') } });
  });

  it('deletes the picked track by GUID', () => {
    render(<TrackInfoBar selectedTrackIdx={2} selectedTrackGuid="{VOX}" />);
    fireEvent.click(screen.getByTitle('Delete track'));
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));
    expect(sendCommand).toHaveBeenCalledWith({ command: 'track/delete', params: { trackGuid: '{VOX}' } });
  });

  it('disarms a pending delete when the shown track changes', () => {
    const { rerender } = render(<TrackInfoBar selectedTrackIdx={2} selectedTrackGuid="{VOX}" />);
    fireEvent.click(screen.getByTitle('Delete track'));
    rerender(<TrackInfoBar selectedTrackIdx={3} selectedTrackGuid="{BASS}" />);
    expect(screen.queryByTitle('Click again to confirm delete')).toBeNull();
    fireEvent.click(screen.getByTitle('Delete track'));
    expect(sendCommand).not.toHaveBeenCalled();
  });

  it('keeps a pending delete armed when the picked track only moves', () => {
    const { rerender } = render(<TrackInfoBar selectedTrackIdx={2} selectedTrackGuid="{VOX}" />);
    fireEvent.click(screen.getByTitle('Delete track'));
    useReaperStore.setState({ tracks: { 3: track(3, '{VOX}', 'Vox') } });
    rerender(<TrackInfoBar selectedTrackIdx={3} selectedTrackGuid="{VOX}" />);
    fireEvent.click(screen.getByTitle('Click again to confirm delete'));
    expect(sendCommand).toHaveBeenCalledWith({ command: 'track/delete', params: { trackGuid: '{VOX}' } });
  });

  it('duplicates and renames the picked track by GUID', () => {
    render(<TrackInfoBar selectedTrackIdx={2} selectedTrackGuid="{VOX}" />);
    fireEvent.click(screen.getByTitle('Duplicate track'));
    expect(sendCommand).toHaveBeenCalledWith({ command: 'track/duplicate', params: { trackGuid: '{VOX}' } });

    fireEvent.click(screen.getByTitle('Click to edit name'));
    const input = screen.getByDisplayValue('Vox');
    fireEvent.change(input, { target: { value: 'Lead Vox' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    expect(sendCommand).toHaveBeenCalledWith({ command: 'track/rename', params: { trackGuid: '{VOX}', name: 'Lead Vox' } });
  });
});
