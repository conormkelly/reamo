/**
 * Tests for MakeSelectionModal - Mode switching behavior
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { MakeSelectionModal } from './MakeSelectionModal';
import { useReaperStore } from '../../store';

// Mock the ReaperProvider
vi.mock('../ReaperProvider', () => ({
  useReaper: () => ({ send: vi.fn() }),
}));

// Reset store before each test
function resetStore() {
  useReaperStore.setState({
    bpm: 120,
    positionBeats: '1.1.00',
    positionSeconds: 0,
    timeSelection: null,
  });
}

// Setup store for project starting at bar -4 (90 BPM)
function setupNegativeBarProject() {
  // Project starts at bar -4, which is time 0
  // At 90 BPM: 1 bar = 4 beats = 4 * (60/90) = 2.667 seconds
  // Bar 9 is at: (9 - (-4) - 1) * 2.667 = 12 bars * 2.667 = 32 seconds from bar -4
  // Actually: from bar -4 to bar 9, skipping bar 0: -4,-3,-2,-1,1,2,3,4,5,6,7,8,9 = 13 bars
  // Wait, bar -4 to bar 9: the gap is 9 - (-4) = 13, but we skip bar 0
  // Bars: -4,-3,-2,-1,1,2,3,4,5,6,7,8,9 - that's 13 bars total, 12 transitions
  // Hmm, let me recalculate: bar -4 is at time 0, bar 9 is at (13-1)*2.667 = 32 seconds? No...
  // If bar -4 is at beat 0, bar 9 is at beat (13 bars * 4 beats) = 52 beats... no
  // Let's say: bar -4 beat 1 = beat 0, bar -3 beat 1 = beat 4, bar -2 beat 1 = beat 8...
  // bar 1 beat 1 = beat 20 (5 bars * 4 = 20), bar 9 beat 1 = beat 52 (13 bars * 4 = 52)
  // At 90 BPM: beat 52 = 52 * (60/90) = 34.667 seconds
  useReaperStore.setState({
    bpm: 90,
    positionBeats: '9.1.00', // Currently at bar 9
    positionSeconds: 34.667,
    // barOffset = -5 makes beat 0 display as bar -4 (calculatedBar 1 + (-5) = -4)
    barOffset: -5,
    // Time selection from bar 1 to bar 9 (stored as beats from time 0)
    // Bar 1.1 = 20 beats, Bar 9.1 = 52 beats (at 90 BPM: 13.333s to 34.667s)
    timeSelection: {
      startBeats: 20,
      endBeats: 52,
    },
  });
}

describe('MakeSelectionModal', () => {
  beforeEach(() => {
    resetStore();
  });

  describe('mode switching', () => {
    it('defaults to beats mode with bar.beat format', () => {
      render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);

      const startInput = screen.getByPlaceholderText('1.1') as HTMLInputElement;
      const endInput = screen.getByPlaceholderText('2.1') as HTMLInputElement;

      // Should have bar.beat format
      expect(startInput.value).toBe('1.1');
      expect(endInput.value).toBe('2.1');
    });

    it('reformats values when switching from beats to time mode', () => {
      render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);

      // Get initial values in beats mode
      const startInput = screen.getByPlaceholderText('1.1') as HTMLInputElement;
      expect(startInput.value).toBe('1.1');

      // Switch to time mode
      const timeButton = screen.getByRole('button', { name: 'Time' });
      fireEvent.click(timeButton);

      // Values should now be in time format (MM:SS.mmm)
      // At 120 BPM: bar 1 beat 1 = 0 seconds, bar 2 beat 1 = 2 seconds (4 beats)
      const startInputAfter = screen.getByPlaceholderText('0:00.000') as HTMLInputElement;
      const endInputAfter = screen.getByPlaceholderText('0:30.000') as HTMLInputElement;

      // Should have time format, not bar.beat format
      expect(startInputAfter.value).toMatch(/^\d+:\d{2}\.\d{3}$/);
      expect(endInputAfter.value).toMatch(/^\d+:\d{2}\.\d{3}$/);

      // Should NOT still be in bar.beat format
      expect(startInputAfter.value).not.toBe('1.1');
      expect(endInputAfter.value).not.toBe('2.1');
    });

    it('reformats values when switching from time to beats mode', () => {
      render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);

      // Switch to time mode first
      const timeButton = screen.getByRole('button', { name: 'Time' });
      fireEvent.click(timeButton);

      // Verify we're in time mode
      const startInputTime = screen.getByPlaceholderText('0:00.000') as HTMLInputElement;
      expect(startInputTime.value).toMatch(/^\d+:\d{2}\.\d{3}$/);

      // Switch back to beats mode
      const beatsButton = screen.getByRole('button', { name: 'Bars.Beats' });
      fireEvent.click(beatsButton);

      // Values should be in bar.beat format again
      const startInputBeats = screen.getByPlaceholderText('1.1') as HTMLInputElement;
      expect(startInputBeats.value).toMatch(/^\d+\.\d/);
    });

    it('correctly converts time values when switching modes', () => {
      // Set BPM to 120 (1 beat = 0.5 seconds, 4 beats = 2 seconds)
      useReaperStore.setState({ bpm: 120 });

      render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);

      // Default is 1.1 to 2.1 (0 to 4 beats = 0 to 2 seconds at 120 BPM)
      const startInput = screen.getByPlaceholderText('1.1') as HTMLInputElement;
      expect(startInput.value).toBe('1.1');

      // Switch to time mode
      const timeButton = screen.getByRole('button', { name: 'Time' });
      fireEvent.click(timeButton);

      // Check time values
      const startInputTime = screen.getByPlaceholderText('0:00.000') as HTMLInputElement;
      const endInputTime = screen.getByPlaceholderText('0:30.000') as HTMLInputElement;

      // Bar 1 beat 1 = 0 seconds
      expect(startInputTime.value).toBe('0:00.000');
      // Bar 2 beat 1 = 2 seconds (4 beats at 120 BPM)
      expect(endInputTime.value).toBe('0:02.000');
    });
  });

  describe('projects with negative start bar', () => {
    it('displays correct bar.beat for project starting at bar -4', () => {
      setupNegativeBarProject();
      render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);

      // Time selection is from bar 1.1 to bar 9.1
      const startInput = screen.getByPlaceholderText('1.1') as HTMLInputElement;
      const endInput = screen.getByPlaceholderText('2.1') as HTMLInputElement;

      expect(startInput.value).toBe('1.1');
      expect(endInput.value).toBe('9.1');
    });

    it('converts correctly to time for project starting at bar -4', () => {
      setupNegativeBarProject();
      render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);

      // Switch to time mode
      const timeButton = screen.getByRole('button', { name: 'Time' });
      fireEvent.click(timeButton);

      // Check time values
      const startInputTime = screen.getByPlaceholderText('0:00.000') as HTMLInputElement;
      const endInputTime = screen.getByPlaceholderText('0:30.000') as HTMLInputElement;

      // Bar 1.1 = 13.333 seconds (20 beats at 90 BPM)
      expect(startInputTime.value).toBe('0:13.333');
      // Bar 9.1 = 34.667 seconds (52 beats at 90 BPM)
      expect(endInputTime.value).toBe('0:34.667');
    });

    it('round-trips correctly: beats -> time -> beats', () => {
      setupNegativeBarProject();
      render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);

      // Verify initial values
      let startInput = screen.getByPlaceholderText('1.1') as HTMLInputElement;
      expect(startInput.value).toBe('1.1');

      // Switch to time
      const timeButton = screen.getByRole('button', { name: 'Time' });
      fireEvent.click(timeButton);

      // Switch back to beats
      const beatsButton = screen.getByRole('button', { name: 'Bars.Beats' });
      fireEvent.click(beatsButton);

      // Should be back to original values
      startInput = screen.getByPlaceholderText('1.1') as HTMLInputElement;
      const endInput = screen.getByPlaceholderText('2.1') as HTMLInputElement;

      expect(startInput.value).toBe('1.1');
      expect(endInput.value).toBe('9.1');
    });

    it('handles position changes during modal use without affecting conversion', () => {
      setupNegativeBarProject();
      render(<MakeSelectionModal isOpen={true} onClose={() => {}} />);

      // Verify initial values
      let startInput = screen.getByPlaceholderText('1.1') as HTMLInputElement;
      expect(startInput.value).toBe('1.1');

      // Simulate playback changing position (but still same barOffset)
      act(() => {
        useReaperStore.setState({
          positionBeats: '5.1.00',
          positionSeconds: 24.0, // Different position, same project
        });
      });

      // Switch to time
      const timeButton = screen.getByRole('button', { name: 'Time' });
      fireEvent.click(timeButton);

      // Check time values are still correct
      const startInputTime = screen.getByPlaceholderText('0:00.000') as HTMLInputElement;
      expect(startInputTime.value).toBe('0:13.333');

      // Switch back to beats
      const beatsButton = screen.getByRole('button', { name: 'Bars.Beats' });
      fireEvent.click(beatsButton);

      // Should still be correct
      startInput = screen.getByPlaceholderText('1.1') as HTMLInputElement;
      expect(startInput.value).toBe('1.1');
    });
  });
});
