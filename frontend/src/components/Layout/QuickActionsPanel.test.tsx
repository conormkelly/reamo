/**
 * QuickActionsPanel - Count-in & Pre-roll toggle tests
 *
 * Scoped to the count-in and pre-roll buttons added in 78d8a408.
 * Other QuickActionsPanel features (save, undo, metronome, tempo, timesig) are out of scope.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';

// Vitest 4.x: setup.ts pre-caches modules before vi.mock can intercept.
// resetModules forces re-evaluation so mocks apply to transitive imports.
vi.hoisted(() => vi.resetModules());

// Mock dependencies
const mockSendCommand = vi.fn();
const mockSendCommandAsync = vi.fn();

vi.mock('../ReaperProvider', () => ({
  useReaper: vi.fn(() => ({
    sendCommand: mockSendCommand,
    sendCommandAsync: mockSendCommandAsync,
  })),
}));

vi.mock('../Modal/BottomSheet', () => ({
  BottomSheet: ({ isOpen, children }: any) => (isOpen ? <div>{children}</div> : null),
}));

vi.mock('../../hooks', () => ({
  useTimeSignature: vi.fn(() => ({ beatsPerBar: 4, denominator: 4 })),
}));

const mockCountInTogglePlayback = vi.fn(() => ({ command: 'countIn/togglePlayback' }));
const mockCountInToggleRecord = vi.fn(() => ({ command: 'countIn/toggleRecord' }));
const mockActionExecute = vi.fn((id: number) => ({ command: 'action/execute', params: { commandId: id } }));

vi.mock('../../core/WebSocketCommands', () => ({
  action: {
    execute: (...args: any[]) => mockActionExecute(...args),
  },
  metronome: { toggle: vi.fn(() => ({ command: 'metronome/toggle' })) },
  countIn: {
    togglePlayback: (...args: any[]) => mockCountInTogglePlayback(...args),
    toggleRecord: (...args: any[]) => mockCountInToggleRecord(...args),
  },
  repeat: { toggle: vi.fn(() => ({ command: 'repeat/toggle' })) },
  tempo: {
    set: vi.fn(),
    tap: vi.fn(() => ({ command: 'tempo/tap' })),
  },
  timesig: { set: vi.fn() },
}));

type SelectorFn = (state: any) => any;

const createMockState = (overrides: Record<string, any> = {}) => ({
  projectName: 'Test.rpp',
  isProjectDirty: false,
  reaperCanUndo: false,
  reaperCanRedo: false,
  showUndo: vi.fn(),
  showRedo: vi.fn(),
  isMetronome: false,
  isRepeat: false,
  isCountInPlayback: false,
  isCountInRecord: false,
  isPreRollPlay: false,
  isPreRollRecord: false,
  bpm: 120,
  setBpm: vi.fn(),
  ...overrides,
});

vi.mock('../../store', () => ({
  useReaperStore: vi.fn((selector: SelectorFn) => selector(createMockState())),
}));

import { QuickActionsPanel } from './QuickActionsPanel';
import { useReaperStore } from '../../store';

describe('QuickActionsPanel - Count-in & Pre-roll', () => {
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

  describe('count-in playback toggle', () => {
    it('shows aria-pressed=false when count-in playback is off', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState({ isCountInPlayback: false }))
      );
      render(<QuickActionsPanel {...defaultProps} />);

      const btn = screen.getByTitle('Count-in before playback');
      expect(btn).toHaveAttribute('aria-pressed', 'false');
    });

    it('shows aria-pressed=true when count-in playback is on', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState({ isCountInPlayback: true }))
      );
      render(<QuickActionsPanel {...defaultProps} />);

      const btn = screen.getByTitle('Count-in before playback');
      expect(btn).toHaveAttribute('aria-pressed', 'true');
    });

    it('sends countIn.togglePlayback command on click', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState())
      );
      render(<QuickActionsPanel {...defaultProps} />);

      fireEvent.click(screen.getByTitle('Count-in before playback'));
      expect(mockCountInTogglePlayback).toHaveBeenCalled();
      expect(mockSendCommand).toHaveBeenCalled();
    });
  });

  describe('count-in record toggle', () => {
    it('reflects isCountInRecord state via aria-pressed', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState({ isCountInRecord: true }))
      );
      render(<QuickActionsPanel {...defaultProps} />);

      expect(screen.getByTitle('Count-in before recording')).toHaveAttribute('aria-pressed', 'true');
    });

    it('sends countIn.toggleRecord command on click', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState())
      );
      render(<QuickActionsPanel {...defaultProps} />);

      fireEvent.click(screen.getByTitle('Count-in before recording'));
      expect(mockCountInToggleRecord).toHaveBeenCalled();
      expect(mockSendCommand).toHaveBeenCalled();
    });
  });

  describe('pre-roll playback toggle', () => {
    it('shows aria-pressed=false when pre-roll playback is off', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState({ isPreRollPlay: false }))
      );
      render(<QuickActionsPanel {...defaultProps} />);

      expect(screen.getByTitle('Pre-roll before playback')).toHaveAttribute('aria-pressed', 'false');
    });

    it('shows aria-pressed=true when pre-roll playback is on', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState({ isPreRollPlay: true }))
      );
      render(<QuickActionsPanel {...defaultProps} />);

      expect(screen.getByTitle('Pre-roll before playback')).toHaveAttribute('aria-pressed', 'true');
    });

    it('sends action.execute(41818) on click', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState())
      );
      render(<QuickActionsPanel {...defaultProps} />);

      fireEvent.click(screen.getByTitle('Pre-roll before playback'));
      expect(mockActionExecute).toHaveBeenCalledWith(41818);
      expect(mockSendCommand).toHaveBeenCalled();
    });
  });

  describe('pre-roll record toggle', () => {
    it('reflects isPreRollRecord state via aria-pressed', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState({ isPreRollRecord: true }))
      );
      render(<QuickActionsPanel {...defaultProps} />);

      expect(screen.getByTitle('Pre-roll before recording')).toHaveAttribute('aria-pressed', 'true');
    });

    it('sends action.execute(41819) on click', () => {
      vi.mocked(useReaperStore).mockImplementation((selector: SelectorFn) =>
        selector(createMockState())
      );
      render(<QuickActionsPanel {...defaultProps} />);

      fireEvent.click(screen.getByTitle('Pre-roll before recording'));
      expect(mockActionExecute).toHaveBeenCalledWith(41819);
      expect(mockSendCommand).toHaveBeenCalled();
    });
  });
});
