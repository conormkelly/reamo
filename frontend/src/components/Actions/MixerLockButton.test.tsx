/**
 * MixerLockButton Component Tests
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { MixerLockButton } from './MixerLockButton';

// Mock store
const mockToggleMixerLock = vi.fn();

const createMockState = (mixerLocked: boolean) => ({
  mixerLocked,
  toggleMixerLock: mockToggleMixerLock,
});

type SelectorFn = (state: any) => any;

vi.mock('../../store', () => ({
  useReaperStore: vi.fn((selector: SelectorFn) => selector(createMockState(false))),
}));

import { useReaperStore } from '../../store';

describe('MixerLockButton', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    cleanup();
  });

  describe('unlocked state', () => {
    beforeEach(() => {
      vi.mocked(useReaperStore).mockImplementation(
        (selector: SelectorFn) => selector(createMockState(false))
      );
    });

    it('renders unlock icon when not locked', () => {
      render(<MixerLockButton />);

      // Unlock icon should be present (lucide-react renders SVG)
      const button = screen.getByRole('button');
      expect(button).toBeInTheDocument();
    });

    it('shows correct title when unlocked', () => {
      render(<MixerLockButton />);

      const button = screen.getByRole('button');
      expect(button).toHaveAttribute('title', 'Lock mixer controls');
    });

    it('has aria-pressed false when unlocked', () => {
      render(<MixerLockButton />);

      const button = screen.getByRole('button');
      expect(button).toHaveAttribute('aria-pressed', 'false');
    });

    it('applies unlocked styling', () => {
      render(<MixerLockButton />);

      const button = screen.getByRole('button');
      expect(button).toHaveClass('bg-bg-elevated');
      expect(button).toHaveClass('text-text-tertiary');
      expect(button).not.toHaveClass('bg-warning');
    });
  });

  describe('locked state', () => {
    beforeEach(() => {
      vi.mocked(useReaperStore).mockImplementation(
        (selector: SelectorFn) => selector(createMockState(true))
      );
    });

    it('renders lock icon when locked', () => {
      render(<MixerLockButton />);

      const button = screen.getByRole('button');
      expect(button).toBeInTheDocument();
    });

    it('shows correct title when locked', () => {
      render(<MixerLockButton />);

      const button = screen.getByRole('button');
      expect(button).toHaveAttribute('title', 'Unlock mixer controls');
    });

    it('has aria-pressed true when locked', () => {
      render(<MixerLockButton />);

      const button = screen.getByRole('button');
      expect(button).toHaveAttribute('aria-pressed', 'true');
    });

    it('applies locked styling', () => {
      render(<MixerLockButton />);

      const button = screen.getByRole('button');
      expect(button).toHaveClass('bg-warning');
      expect(button).toHaveClass('text-text-primary');
    });
  });

  describe('click behavior', () => {
    it('calls toggleMixerLock when clicked', () => {
      vi.mocked(useReaperStore).mockImplementation(
        (selector: SelectorFn) => selector(createMockState(false))
      );

      render(<MixerLockButton />);

      fireEvent.click(screen.getByRole('button'));

      expect(mockToggleMixerLock).toHaveBeenCalledTimes(1);
    });
  });

  describe('styling', () => {
    it('has correct base classes', () => {
      vi.mocked(useReaperStore).mockImplementation(
        (selector: SelectorFn) => selector(createMockState(false))
      );

      render(<MixerLockButton />);

      const button = screen.getByRole('button');
      expect(button).toHaveClass('p-2');
      expect(button).toHaveClass('rounded');
      expect(button).toHaveClass('transition-colors');
    });
  });
});
