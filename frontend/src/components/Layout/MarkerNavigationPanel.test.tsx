import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';

// Vitest 4.x: setup.ts pre-caches modules before vi.mock can intercept.
// resetModules forces re-evaluation so mocks apply to transitive imports.
vi.hoisted(() => vi.resetModules());

// Mock dependencies
const mockSendCommand = vi.fn();

vi.mock('../ReaperProvider', () => ({
  useReaper: vi.fn(() => ({
    sendCommand: mockSendCommand,
  })),
}));

vi.mock('../Modal/BottomSheet', () => ({
  BottomSheet: ({ isOpen, children }: any) => (isOpen ? <div>{children}</div> : null),
}));

vi.mock('../../core/WebSocketCommands', () => ({
  transport: {
    seek: vi.fn((pos: number) => ({ command: 'transport/seek', params: { position: pos } })),
  },
  action: {
    execute: vi.fn((id: number) => ({ command: 'action/execute', params: { commandId: id } })),
  },
}));

vi.mock('../../utils', () => ({
  formatTime: vi.fn((pos: number) => `${pos.toFixed(1)}s`),
  reaperColorToHexWithFallback: vi.fn(() => '#888'),
}));

import { MarkerNavigationPanel } from './MarkerNavigationPanel';
import { useReaperStore } from '../../store';
import { transport, action } from '../../core/WebSocketCommands';

type SelectorFn = (state: any) => any;

const createMockState = (
  markers: Array<{ id: number; name: string; position: number; positionBars?: string; color?: number }> = [],
  regions: Array<{ id: number; name: string; start: number; startBars?: string; color?: number }> = []
) => ({
  markers,
  regions,
});

vi.mock('../../store', () => ({
  useReaperStore: vi.fn((selector: SelectorFn) => selector(createMockState())),
}));

describe('MarkerNavigationPanel', () => {
  const defaultProps = {
    isOpen: true,
    onClose: vi.fn(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterEach(() => {
    cleanup();
  });

  describe('pinned navigation buttons', () => {
    it('renders Start of Project button', () => {
      render(<MarkerNavigationPanel {...defaultProps} />);
      expect(screen.getByText('Start of Project')).toBeInTheDocument();
    });

    it('renders End of Project button', () => {
      render(<MarkerNavigationPanel {...defaultProps} />);
      expect(screen.getByText('End of Project')).toBeInTheDocument();
    });

    it('sends action 40042 and closes on Start of Project click', () => {
      render(<MarkerNavigationPanel {...defaultProps} />);
      fireEvent.click(screen.getByText('Start of Project'));

      expect(action.execute).toHaveBeenCalledWith(40042);
      expect(mockSendCommand).toHaveBeenCalled();
      expect(defaultProps.onClose).toHaveBeenCalled();
    });

    it('sends action 40043 and closes on End of Project click', () => {
      render(<MarkerNavigationPanel {...defaultProps} />);
      fireEvent.click(screen.getByText('End of Project'));

      expect(action.execute).toHaveBeenCalledWith(40043);
      expect(mockSendCommand).toHaveBeenCalled();
      expect(defaultProps.onClose).toHaveBeenCalled();
    });
  });

  describe('marker and region list', () => {
    it('renders markers and regions sorted by position', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(
          createMockState(
            [{ id: 1, name: 'Chorus', position: 30 }],
            [{ id: 1, name: 'Intro', start: 0 }]
          )
        )
      );

      render(<MarkerNavigationPanel {...defaultProps} />);

      const items = screen.getAllByRole('option');
      expect(items).toHaveLength(2);
      // Intro (pos 0) should appear before Chorus (pos 30)
      expect(items[0]).toHaveTextContent('Intro');
      expect(items[1]).toHaveTextContent('Chorus');
    });

    it('seeks to position and closes on marker click', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(
          createMockState([{ id: 1, name: 'Bridge', position: 45.5 }])
        )
      );

      render(<MarkerNavigationPanel {...defaultProps} />);
      fireEvent.click(screen.getByRole('option'));

      expect(transport.seek).toHaveBeenCalledWith(45.5);
      expect(mockSendCommand).toHaveBeenCalled();
      expect(defaultProps.onClose).toHaveBeenCalled();
    });
  });

  describe('empty state', () => {
    it('shows empty message when no markers or regions', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState())
      );

      render(<MarkerNavigationPanel {...defaultProps} />);
      expect(screen.getByText('No markers or regions in project')).toBeInTheDocument();
    });
  });

  describe('footer', () => {
    it('shows correct marker and region counts', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(
          createMockState(
            [
              { id: 1, name: 'M1', position: 0 },
              { id: 2, name: 'M2', position: 10 },
            ],
            [{ id: 1, name: 'R1', start: 5 }]
          )
        )
      );

      render(<MarkerNavigationPanel {...defaultProps} />);
      expect(screen.getByText(/2 markers/)).toBeInTheDocument();
      expect(screen.getByText(/1 region(?!s)/)).toBeInTheDocument();
    });
  });
});
