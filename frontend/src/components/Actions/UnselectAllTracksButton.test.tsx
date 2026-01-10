/**
 * UnselectAllTracksButton Component Tests
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { UnselectAllTracksButton } from './UnselectAllTracksButton';

// Mock dependencies
const mockSendCommand = vi.fn();

vi.mock('../ReaperProvider', () => ({
  useReaper: vi.fn(() => ({
    sendCommand: mockSendCommand,
  })),
}));

vi.mock('../../hooks', () => ({
  useTracks: vi.fn(() => ({
    selectedTracks: [],
  })),
}));

vi.mock('../../core/WebSocketCommands', () => ({
  track: {
    unselectAll: vi.fn(() => ({
      command: 'track/unselectAll',
      params: {},
    })),
  },
}));

import { useTracks } from '../../hooks';
import { track as trackCmd } from '../../core/WebSocketCommands';

describe('UnselectAllTracksButton', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    cleanup();
  });

  describe('visibility', () => {
    it('returns null when no tracks are selected', () => {
      vi.mocked(useTracks).mockReturnValue({
        selectedTracks: [],
      } as unknown as ReturnType<typeof useTracks>);

      const { container } = render(<UnselectAllTracksButton />);
      expect(container.firstChild).toBeNull();
    });

    it('renders button when tracks are selected', () => {
      vi.mocked(useTracks).mockReturnValue({
        selectedTracks: [{ index: 1, name: 'Track 1' }],
      } as unknown as ReturnType<typeof useTracks>);

      render(<UnselectAllTracksButton />);

      const button = screen.getByRole('button');
      expect(button).toBeInTheDocument();
    });

    it('renders when multiple tracks are selected', () => {
      vi.mocked(useTracks).mockReturnValue({
        selectedTracks: [
          { index: 1, name: 'Track 1' },
          { index: 2, name: 'Track 2' },
          { index: 3, name: 'Track 3' },
        ],
      } as unknown as ReturnType<typeof useTracks>);

      render(<UnselectAllTracksButton />);

      const button = screen.getByRole('button');
      expect(button).toBeInTheDocument();
    });
  });

  describe('click behavior', () => {
    beforeEach(() => {
      vi.mocked(useTracks).mockReturnValue({
        selectedTracks: [{ index: 1, name: 'Track 1' }],
      } as unknown as ReturnType<typeof useTracks>);
    });

    it('sends unselectAll command when clicked', () => {
      render(<UnselectAllTracksButton />);

      fireEvent.click(screen.getByRole('button'));

      expect(trackCmd.unselectAll).toHaveBeenCalledTimes(1);
      expect(mockSendCommand).toHaveBeenCalledTimes(1);
      expect(mockSendCommand).toHaveBeenCalledWith({
        command: 'track/unselectAll',
        params: {},
      });
    });
  });

  describe('styling', () => {
    beforeEach(() => {
      vi.mocked(useTracks).mockReturnValue({
        selectedTracks: [{ index: 1, name: 'Track 1' }],
      } as unknown as ReturnType<typeof useTracks>);
    });

    it('has correct title', () => {
      render(<UnselectAllTracksButton />);

      const button = screen.getByRole('button');
      expect(button).toHaveAttribute('title', 'Deselect all tracks');
    });

    it('has correct base classes', () => {
      render(<UnselectAllTracksButton />);

      const button = screen.getByRole('button');
      expect(button).toHaveClass('p-2');
      expect(button).toHaveClass('rounded');
      expect(button).toHaveClass('transition-colors');
      expect(button).toHaveClass('bg-bg-elevated');
      expect(button).toHaveClass('text-text-tertiary');
    });
  });
});
