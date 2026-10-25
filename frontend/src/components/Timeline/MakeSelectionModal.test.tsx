/**
 * Tests for MakeSelectionModal
 *
 * Bar positions are converted by REAPER through the project's tempo map. The
 * fake server here has a tempo change: 120 BPM for bars 1-4 (2 s a bar),
 * then 60 BPM (4 s a bar), so bar 5 is at 8 s and bar 6 at 12 s. Converting
 * on the phone with one tempo would put bar 6 at 10 s.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { useReaperStore } from '../../store';

vi.hoisted(() => vi.resetModules());

const sendCommand = vi.fn();
const sendAsync = vi.fn();
vi.mock('../ReaperProvider', () => ({
  useReaper: () => ({ sendCommand, sendAsync }),
}));

const { MakeSelectionModal } = await import('./MakeSelectionModal');

/** Seconds at bar.beat.ticks in the fake tempo map (4/4) */
function barTime(bar: number, beat: number, ticks: number): number {
  const beats = (bar - 1) * 4 + (beat - 1) + ticks / 100;
  return beats <= 16 ? beats * 0.5 : 8 + (beats - 16);
}

/** Ruler label at a time in the fake tempo map */
function timeLabel(time: number): string {
  const beats = time <= 8 ? time / 0.5 : 16 + (time - 8);
  const bar = Math.floor(beats / 4) + 1;
  const beat = Math.floor(beats % 4) + 1;
  const ticks = Math.round((beats % 1) * 100);
  return `${bar}.${beat}.${String(ticks).padStart(2, '0')}`;
}

function fakeReaper(command: string, params?: Record<string, unknown>) {
  const p = params as Record<string, number>;
  if (command === 'tempo/barsToTime') {
    if (p.bar < 1) return Promise.resolve({ success: false, error: { code: 'INVALID_BAR' } });
    return Promise.resolve({ success: true, payload: { time: barTime(p.bar, p.beat, p.ticks) } });
  }
  if (command === 'tempo/timeToBeats') {
    return Promise.resolve({ success: true, payload: { bars: timeLabel(p.time) } });
  }
  return Promise.reject(new Error(`unexpected ${command}`));
}

function inputs() {
  const [start, end] = screen.getAllByRole('textbox') as HTMLInputElement[];
  return { start, end };
}

describe('MakeSelectionModal', () => {
  beforeEach(() => {
    sendCommand.mockReset();
    sendAsync.mockReset();
    sendAsync.mockImplementation(fakeReaper);
    useReaperStore.setState({ bpm: 120, timeSelection: null });
  });

  it('defaults to bar 1 to bar 2', () => {
    render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);
    expect(inputs().start.value).toBe('1.1');
    expect(inputs().end.value).toBe('2.1');
  });

  it('selects the times REAPER gives for the bars, across a tempo change', async () => {
    const onClose = vi.fn();
    render(<MakeSelectionModal isOpen={true} onClose={onClose} />);
    fireEvent.change(inputs().start, { target: { value: '5.1' } });
    fireEvent.change(inputs().end, { target: { value: '6.1' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(sendCommand).toHaveBeenCalledWith({ command: 'timeSelection/set', params: { start: 8, end: 12 } });
  });

  it('shows the current selection as REAPER labels it', async () => {
    useReaperStore.setState({ timeSelection: { startSeconds: 8, endSeconds: 12 } });
    render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);
    await waitFor(() => expect(inputs().start.value).toBe('5.1'));
    expect(inputs().end.value).toBe('6.1');
  });

  it('converts typed bars to time and back through REAPER when switching modes', async () => {
    render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);
    fireEvent.change(inputs().start, { target: { value: '5.1' } });
    fireEvent.change(inputs().end, { target: { value: '6.1' } });

    fireEvent.click(screen.getByRole('button', { name: 'Time' }));
    await waitFor(() => expect(inputs().start.value).toBe('0:08.000'));
    expect(inputs().end.value).toBe('0:12.000');

    fireEvent.click(screen.getByRole('button', { name: 'Bars.Beats' }));
    await waitFor(() => expect(inputs().start.value).toBe('5.1'));
    expect(inputs().end.value).toBe('6.1');
  });

  it('sets nothing when REAPER cannot place a bar, and says so', async () => {
    const onClose = vi.fn();
    render(<MakeSelectionModal isOpen={true} onClose={onClose} />);
    fireEvent.change(inputs().start, { target: { value: '-3.1' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    expect(await screen.findByText(/REAPER couldn't place the start/)).toBeTruthy();
    expect(sendCommand).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
  });

  it('refuses text that is not a bar position, without asking REAPER', () => {
    render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);
    fireEvent.change(inputs().end, { target: { value: 'soon' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    expect(screen.getByText('End must be a valid position (e.g., 2.1 or 10.1)')).toBeTruthy();
    expect(sendAsync).not.toHaveBeenCalled();
  });

  it('applies typed times directly', async () => {
    const onClose = vi.fn();
    render(<MakeSelectionModal isOpen={true} onClose={onClose} />);
    fireEvent.click(screen.getByRole('button', { name: 'Time' }));
    await waitFor(() => expect(inputs().end.value).toBe('0:02.000'));
    fireEvent.change(inputs().start, { target: { value: '1:30' } });
    fireEvent.change(inputs().end, { target: { value: '1:00' } });
    fireEvent.click(screen.getByRole('button', { name: 'Apply' }));
    await waitFor(() => expect(onClose).toHaveBeenCalled());
    expect(sendCommand).toHaveBeenCalledWith({ command: 'timeSelection/set', params: { start: 60, end: 90 } });
  });
});
