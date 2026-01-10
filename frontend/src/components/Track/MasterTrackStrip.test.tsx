/**
 * MasterTrackStrip Component Tests
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { MasterTrackStrip } from './MasterTrackStrip';

// Mock dependencies
vi.mock('./LevelMeter', () => ({
  LevelMeter: vi.fn(({ trackIndex, height }) => (
    <div data-testid="level-meter" data-track-index={trackIndex} data-height={height}>
      LevelMeter
    </div>
  )),
}));

vi.mock('./TrackStrip', () => ({
  TrackStrip: vi.fn(({ trackIndex }) => (
    <div data-testid="track-strip" data-track-index={trackIndex}>
      TrackStrip
    </div>
  )),
}));

describe('MasterTrackStrip', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    cleanup();
  });

  describe('rendering', () => {
    it('renders LevelMeter with trackIndex 0', () => {
      render(<MasterTrackStrip />);

      const meter = screen.getByTestId('level-meter');
      expect(meter).toBeInTheDocument();
      expect(meter).toHaveAttribute('data-track-index', '0');
    });

    it('renders LevelMeter with height 200', () => {
      render(<MasterTrackStrip />);

      const meter = screen.getByTestId('level-meter');
      expect(meter).toHaveAttribute('data-height', '200');
    });

    it('renders TrackStrip with trackIndex 0', () => {
      render(<MasterTrackStrip />);

      const strip = screen.getByTestId('track-strip');
      expect(strip).toBeInTheDocument();
      expect(strip).toHaveAttribute('data-track-index', '0');
    });

    it('renders meter and strip in flex container', () => {
      const { container } = render(<MasterTrackStrip />);

      const wrapper = container.firstChild;
      expect(wrapper).toHaveClass('flex');
      expect(wrapper).toHaveClass('gap-1');
      expect(wrapper).toHaveClass('flex-shrink-0');
    });
  });
});
