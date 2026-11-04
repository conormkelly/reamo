/**
 * TrackInfoBar - acting on the picked track
 *
 * Rename, duplicate and delete must reach the track the user picked, and an
 * armed delete must not carry over to a different track.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react';
import { useReaperStore } from '../../store';
import type { Track } from '../../core/types';

vi.hoisted(() => vi.resetModules());

const sendCommand = vi.fn();
vi.mock('../../hooks/useReaper', () => ({
  useReaper: () => ({ sendCommand, sendAsync: vi.fn(), connected: true }),
}));

vi.mock('./FxModal', () => ({
  FxModal: ({ isOpen }: { isOpen: boolean }) => (isOpen ? <div data-testid="fx-modal" /> : null),
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

/**
 * The FX button: a tap toggles the track's FX, a hold opens the FX list. A
 * press that is neither does nothing.
 */
describe('TrackInfoBar FX button', () => {
  type Point = { x: number; y: number };
  const AT: Point = { x: 100, y: 100 };
  const TOGGLE = { command: 'track/setFxEnabled', params: { trackGuid: '{VOX}', enabled: undefined } };

  function pointer(at: Point, pointerType = 'touch', extra: Record<string, unknown> = {}) {
    return { pointerId: 1, pointerType, isPrimary: true, clientX: at.x, clientY: at.y, button: 0, buttons: 1, ...extra };
  }

  function wait(ms: number) {
    act(() => {
      vi.advanceTimersByTime(ms);
    });
  }

  function setup() {
    render(<TrackInfoBar selectedTrackIdx={2} selectedTrackGuid="{VOX}" />);
    return screen.getByText('FX').closest('button')!;
  }

  const fxModalOpen = () => screen.queryByTestId('fx-modal') !== null;

  beforeEach(() => {
    vi.useFakeTimers();
    sendCommand.mockReset();
    useReaperStore.setState({ tracks: { 2: { ...track(2, '{VOX}', 'Vox'), fxCount: 2 } } });
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it('a tap toggles FX once', () => {
    const fx = setup();

    fireEvent.pointerDown(fx, pointer(AT));
    wait(100);
    fireEvent.pointerUp(fx, pointer(AT, 'touch', { buttons: 0 }));
    fireEvent.click(fx, { detail: 1 });
    wait(1000);

    expect(sendCommand).toHaveBeenCalledTimes(1);
    expect(sendCommand).toHaveBeenCalledWith(TOGGLE);
    expect(fxModalOpen()).toBe(false);
  });

  it('Enter or a screen reader activation (a click with no pointer) toggles FX', () => {
    const fx = setup();

    fireEvent.click(fx, { detail: 0 });

    expect(sendCommand).toHaveBeenCalledTimes(1);
    expect(sendCommand).toHaveBeenCalledWith(TOGGLE);
  });

  it('a hold opens the FX list and its release does not toggle', () => {
    const fx = setup();

    fireEvent.pointerDown(fx, pointer(AT));
    wait(600);
    fireEvent.pointerUp(fx, pointer(AT, 'touch', { buttons: 0 }));
    fireEvent.click(fx, { detail: 1 });

    expect(fxModalOpen()).toBe(true);
    expect(sendCommand).not.toHaveBeenCalled();
  });

  it('a keyboard tap after a hold that ended without a click still toggles', () => {
    const fx = setup();

    // The hold opens the FX list, then the finger slides off: no click follows.
    fireEvent.pointerDown(fx, pointer(AT));
    wait(600);
    fireEvent.pointerLeave(fx, pointer({ x: AT.x, y: AT.y - 80 }));
    fireEvent.click(fx, { detail: 0 });

    expect(sendCommand).toHaveBeenCalledTimes(1);
    expect(sendCommand).toHaveBeenCalledWith(TOGGLE);
  });

  it('a tap while the track name is being edited commits the rename before toggling', () => {
    const fx = setup();
    fireEvent.click(screen.getByTitle('Click to edit name'));
    const input = screen.getByDisplayValue('Vox');
    expect(document.activeElement).toBe(input);
    fireEvent.change(input, { target: { value: 'Lead' } });

    fireEvent.pointerDown(fx, pointer(AT));
    fireEvent.pointerUp(fx, pointer(AT, 'touch', { buttons: 0 }));

    expect(sendCommand.mock.calls.map(([c]) => c)).toEqual([
      { command: 'track/rename', params: { trackGuid: '{VOX}', name: 'Lead' } },
      TOGGLE,
    ]);
    expect(screen.queryByDisplayValue('Lead')).toBeNull();
  });

  it('a hold while the track name is being edited commits the rename before opening the FX list', () => {
    const fx = setup();
    fireEvent.click(screen.getByTitle('Click to edit name'));
    fireEvent.change(screen.getByDisplayValue('Vox'), { target: { value: 'Lead' } });

    fireEvent.pointerDown(fx, pointer(AT));
    wait(600);

    expect(sendCommand.mock.calls.map(([c]) => c)).toEqual([
      { command: 'track/rename', params: { trackGuid: '{VOX}', name: 'Lead' } },
    ]);
    expect(fxModalOpen()).toBe(true);
  });

  it('a right-button hold neither opens the FX list nor toggles', () => {
    const fx = setup();

    fireEvent.pointerDown(fx, pointer(AT, 'mouse', { button: 2, buttons: 2 }));
    wait(600);
    fireEvent.pointerUp(fx, pointer(AT, 'mouse', { button: 2, buttons: 0 }));

    expect(fxModalOpen()).toBe(false);
    expect(sendCommand).not.toHaveBeenCalled();
  });

  it('a hold ended by the window losing focus does not open the FX list', () => {
    const fx = setup();

    fireEvent.pointerDown(fx, pointer(AT, 'mouse'));
    act(() => {
      window.dispatchEvent(new Event('blur'));
    });
    wait(600);

    expect(fxModalOpen()).toBe(false);
  });

  it('a press dragged past the move tolerance does not open the FX list', () => {
    const fx = setup();

    fireEvent.pointerDown(fx, pointer(AT, 'mouse'));
    fireEvent.pointerMove(fx, pointer({ x: AT.x + 20, y: AT.y }, 'mouse'));
    wait(600);

    expect(fxModalOpen()).toBe(false);
  });

  it('a held Enter toggles once: its key repeats are cancelled, which cancels their clicks', () => {
    const fx = setup();

    const first = fireEvent.keyDown(fx, { key: 'Enter' });
    const repeat = fireEvent.keyDown(fx, { key: 'Enter', repeat: true });

    expect(first).toBe(true);
    expect(repeat).toBe(false);
  });

  it('a hold under way when the shown track changes does not open the FX list', () => {
    const { rerender } = render(<TrackInfoBar selectedTrackIdx={2} selectedTrackGuid="{VOX}" />);
    const fx = screen.getByText('FX').closest('button')!;

    fireEvent.pointerDown(fx, pointer(AT));
    wait(200);
    useReaperStore.setState({
      tracks: { 2: { ...track(2, '{VOX}', 'Vox'), fxCount: 2 }, 3: { ...track(3, '{BASS}', 'Bass'), fxCount: 1 } },
    });
    rerender(<TrackInfoBar selectedTrackIdx={3} selectedTrackGuid="{BASS}" />);
    wait(600);

    expect(fxModalOpen()).toBe(false);
  });
});
