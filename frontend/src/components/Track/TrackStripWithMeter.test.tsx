/**
 * TrackStripWithMeter Component Tests
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { TrackStripWithMeter } from './TrackStripWithMeter';

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

describe('TrackStripWithMeter', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    cleanup();
  });

  describe('rendering', () => {
    it('renders LevelMeter with correct trackIndex', () => {
      render(<TrackStripWithMeter trackIndex={5} />);

      const meter = screen.getByTestId('level-meter');
      expect(meter).toBeInTheDocument();
      expect(meter).toHaveAttribute('data-track-index', '5');
    });

    it('renders LevelMeter with height 200', () => {
      render(<TrackStripWithMeter trackIndex={3} />);

      const meter = screen.getByTestId('level-meter');
      expect(meter).toHaveAttribute('data-height', '200');
    });

    it('renders TrackStrip with correct trackIndex', () => {
      render(<TrackStripWithMeter trackIndex={7} />);

      const strip = screen.getByTestId('track-strip');
      expect(strip).toBeInTheDocument();
      expect(strip).toHaveAttribute('data-track-index', '7');
    });

    it('passes trackIndex correctly to both children', () => {
      render(<TrackStripWithMeter trackIndex={42} />);

      const meter = screen.getByTestId('level-meter');
      const strip = screen.getByTestId('track-strip');

      expect(meter).toHaveAttribute('data-track-index', '42');
      expect(strip).toHaveAttribute('data-track-index', '42');
    });

    it('renders meter and strip in flex container', () => {
      const { container } = render(<TrackStripWithMeter trackIndex={1} />);

      const wrapper = container.firstChild;
      expect(wrapper).toHaveClass('flex');
      expect(wrapper).toHaveClass('gap-1');
      expect(wrapper).toHaveClass('flex-shrink-0');
    });
  });

  describe('different track indices', () => {
    it('handles track index 0 (master)', () => {
      render(<TrackStripWithMeter trackIndex={0} />);

      const meter = screen.getByTestId('level-meter');
      const strip = screen.getByTestId('track-strip');

      expect(meter).toHaveAttribute('data-track-index', '0');
      expect(strip).toHaveAttribute('data-track-index', '0');
    });

    it('handles high track index', () => {
      render(<TrackStripWithMeter trackIndex={999} />);

      const meter = screen.getByTestId('level-meter');
      const strip = screen.getByTestId('track-strip');

      expect(meter).toHaveAttribute('data-track-index', '999');
      expect(strip).toHaveAttribute('data-track-index', '999');
    });
  });
});
