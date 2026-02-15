/**
 * ConnectionStatus and ConnectionBanner Component Tests
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, act } from '@testing-library/react';
import { ConnectionStatus, ConnectionBanner } from './ConnectionStatus';
import type { UseReaperConnectionReturn } from '../hooks/useReaperConnection';

// Vitest 4.x: setup.ts pre-caches modules before vi.mock can intercept.
// resetModules forces re-evaluation so mocks apply to transitive imports.
vi.hoisted(() => vi.resetModules());

// Mock dependencies
const mockRetry = vi.fn();
const mockStart = vi.fn();
const mockStop = vi.fn();
const mockSend = vi.fn();
const mockSendCommand = vi.fn();
const mockSendCommandAsync = vi.fn();
const mockSendAsync = vi.fn();

// Create a full mock that satisfies UseReaperConnectionReturn
const createMockReaperReturn = (overrides: Partial<UseReaperConnectionReturn> = {}): UseReaperConnectionReturn => ({
  connected: true,
  connectionStatus: 'connected',
  errorCount: 0,
  retryCount: 0,
  gaveUp: false,
  start: mockStart,
  stop: mockStop,
  retry: mockRetry,
  send: mockSend,
  sendCommand: mockSendCommand,
  sendCommandAsync: mockSendCommandAsync,
  sendAsync: mockSendAsync,
  ...overrides,
});

vi.mock('./ReaperProvider', () => ({
  useReaper: vi.fn(() => createMockReaperReturn()),
}));

vi.mock('../core/TransportSyncEngine', () => ({
  transportSyncEngine: {
    getNetworkQuality: vi.fn(() => 'good'),
  },
}));

vi.mock('./NetworkStatsModal', () => ({
  NetworkStatsModal: vi.fn(({ isOpen, onClose }) =>
    isOpen ? (
      <div data-testid="network-stats-modal">
        <button onClick={onClose}>Close</button>
      </div>
    ) : null
  ),
}));

// Import mocks for manipulation
import { useReaper } from './ReaperProvider';
import { transportSyncEngine } from '../core/TransportSyncEngine';

describe('ConnectionStatus', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.mocked(useReaper).mockReturnValue(createMockReaperReturn());
    vi.mocked(transportSyncEngine.getNetworkQuality).mockReturnValue('good');
    mockRetry.mockClear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('rendering', () => {
    it('renders dot indicator when connected', () => {
      const { container } = render(<ConnectionStatus />);
      const dot = container.querySelector('.rounded-full');
      expect(dot).toBeInTheDocument();
    });

    it('applies custom className', () => {
      const { container } = render(<ConnectionStatus className="custom-class" />);
      expect(container.firstChild).toHaveClass('custom-class');
    });

    it('shows quality in title when connected', () => {
      render(<ConnectionStatus />);
      const indicator = screen.getByTitle('Connected - Good (hold for stats)');
      expect(indicator).toBeInTheDocument();
    });
  });

  describe('network quality colors', () => {
    it('shows bright green for excellent quality', () => {
      vi.mocked(transportSyncEngine.getNetworkQuality).mockReturnValue('excellent');
      const { container } = render(<ConnectionStatus />);

      act(() => {
        vi.advanceTimersByTime(100); // Initial quality update
      });

      const dot = container.querySelector('.rounded-full');
      expect(dot).toHaveClass('bg-success');
    });

    it('shows green for good quality', () => {
      vi.mocked(transportSyncEngine.getNetworkQuality).mockReturnValue('good');
      const { container } = render(<ConnectionStatus />);

      act(() => {
        vi.advanceTimersByTime(100);
      });

      const dot = container.querySelector('.rounded-full');
      expect(dot).toHaveClass('bg-success');
    });

    it('shows light green for moderate quality', () => {
      vi.mocked(transportSyncEngine.getNetworkQuality).mockReturnValue('moderate');
      const { container } = render(<ConnectionStatus />);

      act(() => {
        vi.advanceTimersByTime(100);
      });

      const dot = container.querySelector('.rounded-full');
      expect(dot).toHaveClass('bg-success/70');
    });

    it('shows yellow for poor quality', () => {
      vi.mocked(transportSyncEngine.getNetworkQuality).mockReturnValue('poor');
      const { container } = render(<ConnectionStatus />);

      act(() => {
        vi.advanceTimersByTime(100);
      });

      const dot = container.querySelector('.rounded-full');
      expect(dot).toHaveClass('bg-warning');
    });
  });

  describe('visibility states', () => {
    it('returns null when gaveUp', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'gave_up',
        errorCount: 5,
        gaveUp: true,
      }));

      const { container } = render(<ConnectionStatus />);
      expect(container.firstChild).toBeNull();
    });

    it('returns null when disconnected with no errors', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'idle',
        errorCount: 0,
        gaveUp: false,
      }));

      const { container } = render(<ConnectionStatus />);
      expect(container.firstChild).toBeNull();
    });

    it('shows pulsing indicator when reconnecting', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'retrying',
        errorCount: 2,
        gaveUp: false,
      }));

      const { container } = render(<ConnectionStatus />);
      const dot = container.querySelector('.rounded-full');
      expect(dot).toHaveClass('animate-connection-pulse');
    });
  });

  describe('long press modal', () => {
    it('opens modal on long press (500ms)', () => {
      render(<ConnectionStatus />);

      const indicator = screen.getByTitle('Connected - Good (hold for stats)');
      fireEvent.pointerDown(indicator);

      expect(screen.queryByTestId('network-stats-modal')).not.toBeInTheDocument();

      act(() => {
        vi.advanceTimersByTime(500);
      });

      expect(screen.getByTestId('network-stats-modal')).toBeInTheDocument();
    });

    it('does not open modal on quick tap', () => {
      render(<ConnectionStatus />);

      const indicator = screen.getByTitle('Connected - Good (hold for stats)');
      fireEvent.pointerDown(indicator);

      act(() => {
        vi.advanceTimersByTime(200);
      });

      fireEvent.pointerUp(indicator);

      act(() => {
        vi.advanceTimersByTime(500);
      });

      expect(screen.queryByTestId('network-stats-modal')).not.toBeInTheDocument();
    });

    it('cancels timer on pointer leave', () => {
      render(<ConnectionStatus />);

      const indicator = screen.getByTitle('Connected - Good (hold for stats)');
      fireEvent.pointerDown(indicator);

      act(() => {
        vi.advanceTimersByTime(200);
      });

      fireEvent.pointerLeave(indicator);

      act(() => {
        vi.advanceTimersByTime(500);
      });

      expect(screen.queryByTestId('network-stats-modal')).not.toBeInTheDocument();
    });

    it('closes modal when onClose is called', () => {
      render(<ConnectionStatus />);

      const indicator = screen.getByTitle('Connected - Good (hold for stats)');
      fireEvent.pointerDown(indicator);

      act(() => {
        vi.advanceTimersByTime(500);
      });

      expect(screen.getByTestId('network-stats-modal')).toBeInTheDocument();

      fireEvent.click(screen.getByText('Close'));

      expect(screen.queryByTestId('network-stats-modal')).not.toBeInTheDocument();
    });
  });

  describe('quality polling', () => {
    it('polls network quality every 500ms when connected', () => {
      vi.mocked(transportSyncEngine.getNetworkQuality).mockClear();
      render(<ConnectionStatus />);

      // Initial call
      expect(transportSyncEngine.getNetworkQuality).toHaveBeenCalledTimes(1);

      // First poll
      act(() => {
        vi.advanceTimersByTime(500);
      });
      expect(transportSyncEngine.getNetworkQuality).toHaveBeenCalledTimes(2);

      // Second poll
      act(() => {
        vi.advanceTimersByTime(500);
      });
      expect(transportSyncEngine.getNetworkQuality).toHaveBeenCalledTimes(3);
    });

    it('stops polling when disconnected', () => {
      vi.mocked(transportSyncEngine.getNetworkQuality).mockClear();
      const { rerender } = render(<ConnectionStatus />);

      expect(transportSyncEngine.getNetworkQuality).toHaveBeenCalledTimes(1);

      // Disconnect
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'idle',
        errorCount: 0,
        gaveUp: false,
      }));
      rerender(<ConnectionStatus />);

      const callCount = vi.mocked(transportSyncEngine.getNetworkQuality).mock.calls.length;

      act(() => {
        vi.advanceTimersByTime(1000);
      });

      // No additional calls
      expect(transportSyncEngine.getNetworkQuality).toHaveBeenCalledTimes(callCount);
    });
  });
});

describe('ConnectionBanner', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.mocked(useReaper).mockReturnValue(createMockReaperReturn());
    mockRetry.mockClear();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('visibility', () => {
    it('returns null when connected', () => {
      const { container } = render(<ConnectionBanner />);
      expect(container.firstChild).toBeNull();
    });

    it('shows banner after grace period when disconnected', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'idle',
        errorCount: 0,
        gaveUp: false,
      }));

      render(<ConnectionBanner />);

      // During grace period
      expect(screen.queryByTestId('connection-banner')).not.toBeInTheDocument();

      // After grace period (2500ms)
      act(() => {
        vi.advanceTimersByTime(2500);
      });

      expect(screen.getByTestId('connection-banner')).toBeInTheDocument();
    });

    it('shows banner immediately when gaveUp', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'gave_up',
        errorCount: 5,
        gaveUp: true,
      }));

      render(<ConnectionBanner />);

      // Even before grace period
      expect(screen.getByTestId('connection-banner')).toBeInTheDocument();
    });

    it('shows banner immediately if was previously connected', () => {
      const { rerender } = render(<ConnectionBanner />);

      // Connected first
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn());
      rerender(<ConnectionBanner />);

      // Then disconnect
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'retrying',
        errorCount: 1,
        gaveUp: false,
      }));
      rerender(<ConnectionBanner />);

      // Should show immediately (was previously connected)
      expect(screen.getByTestId('connection-banner')).toBeInTheDocument();
    });
  });

  describe('banner content', () => {
    it('shows "Connecting..." when no errors', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'idle',
        errorCount: 0,
        gaveUp: false,
      }));

      render(<ConnectionBanner />);

      act(() => {
        vi.advanceTimersByTime(2500);
      });

      expect(screen.getByText('Connecting...')).toBeInTheDocument();
    });

    it('shows reconnecting message with attempt count', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'retrying',
        errorCount: 3,
        gaveUp: false,
      }));

      render(<ConnectionBanner />);

      act(() => {
        vi.advanceTimersByTime(2500);
      });

      expect(screen.getByText('Reconnecting... (attempt 3)')).toBeInTheDocument();
    });

    it('shows "Connection lost" when gaveUp', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'gave_up',
        errorCount: 5,
        gaveUp: true,
      }));

      render(<ConnectionBanner />);

      expect(screen.getByText('Connection lost')).toBeInTheDocument();
    });
  });

  describe('reconnect button', () => {
    it('shows reconnect button when gaveUp', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'gave_up',
        errorCount: 5,
        gaveUp: true,
      }));

      render(<ConnectionBanner />);

      expect(screen.getByRole('button', { name: /reconnect/i })).toBeInTheDocument();
    });

    it('calls retry when reconnect button is clicked', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'gave_up',
        errorCount: 5,
        gaveUp: true,
      }));

      render(<ConnectionBanner />);

      fireEvent.click(screen.getByRole('button', { name: /reconnect/i }));

      expect(mockRetry).toHaveBeenCalledTimes(1);
    });

    it('does not show reconnect button when reconnecting', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'retrying',
        errorCount: 3,
        gaveUp: false,
      }));

      render(<ConnectionBanner />);

      act(() => {
        vi.advanceTimersByTime(2500);
      });

      expect(screen.queryByRole('button', { name: /reconnect/i })).not.toBeInTheDocument();
    });
  });

  describe('accessibility', () => {
    it('has role status and aria-live', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'gave_up',
        errorCount: 5,
        gaveUp: true,
      }));

      render(<ConnectionBanner />);

      const banner = screen.getByTestId('connection-banner');
      expect(banner).toHaveAttribute('role', 'status');
      expect(banner).toHaveAttribute('aria-live', 'polite');
      expect(banner).toHaveAttribute('aria-atomic', 'true');
    });
  });

  describe('styling', () => {
    it('applies error styling when gaveUp', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'gave_up',
        errorCount: 5,
        gaveUp: true,
      }));

      render(<ConnectionBanner />);

      const banner = screen.getByTestId('connection-banner');
      expect(banner).toHaveClass('bg-error/20');
    });

    it('applies warning styling when reconnecting', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'retrying',
        errorCount: 2,
        gaveUp: false,
      }));

      render(<ConnectionBanner />);

      act(() => {
        vi.advanceTimersByTime(2500);
      });

      const banner = screen.getByTestId('connection-banner');
      expect(banner).toHaveClass('bg-warning/20');
    });

    it('applies custom className', () => {
      vi.mocked(useReaper).mockReturnValue(createMockReaperReturn({
        connected: false,
        connectionStatus: 'gave_up',
        errorCount: 5,
        gaveUp: true,
      }));

      render(<ConnectionBanner className="custom-class" />);

      const banner = screen.getByTestId('connection-banner');
      expect(banner).toHaveClass('custom-class');
    });
  });
});
