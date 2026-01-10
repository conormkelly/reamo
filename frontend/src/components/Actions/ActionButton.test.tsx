/**
 * ActionButton and ToggleButton Component Tests
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { ActionButton } from './ActionButton';
import { ToggleButton } from './ToggleButton';

// Mock the ReaperProvider
const mockSendCommand = vi.fn();
vi.mock('../ReaperProvider', () => ({
  useReaper: () => ({
    sendCommand: mockSendCommand,
  }),
}));

describe('ActionButton', () => {
  beforeEach(() => {
    mockSendCommand.mockClear();
  });

  describe('rendering', () => {
    it('renders children content', () => {
      render(<ActionButton actionId={1007}>Play</ActionButton>);
      expect(screen.getByText('Play')).toBeInTheDocument();
    });

    it('renders with title attribute', () => {
      render(<ActionButton actionId={1007} title="Play audio">Play</ActionButton>);
      expect(screen.getByTitle('Play audio')).toBeInTheDocument();
    });

    it('applies custom className', () => {
      render(<ActionButton actionId={1007} className="custom-class">Play</ActionButton>);
      expect(screen.getByRole('button')).toHaveClass('custom-class');
    });
  });

  describe('variants', () => {
    it('applies default variant classes', () => {
      render(<ActionButton actionId={1007} variant="default">Test</ActionButton>);
      expect(screen.getByRole('button')).toHaveClass('bg-bg-elevated');
    });

    it('applies primary variant classes', () => {
      render(<ActionButton actionId={1007} variant="primary">Test</ActionButton>);
      expect(screen.getByRole('button')).toHaveClass('bg-primary');
    });

    it('applies danger variant classes', () => {
      render(<ActionButton actionId={1007} variant="danger">Test</ActionButton>);
      expect(screen.getByRole('button')).toHaveClass('bg-error-action');
    });

    it('applies ghost variant classes', () => {
      render(<ActionButton actionId={1007} variant="ghost">Test</ActionButton>);
      expect(screen.getByRole('button')).toHaveClass('bg-transparent');
    });
  });

  describe('sizes', () => {
    it('applies small size classes', () => {
      render(<ActionButton actionId={1007} size="sm">Test</ActionButton>);
      expect(screen.getByRole('button')).toHaveClass('px-2', 'py-1', 'text-sm');
    });

    it('applies medium size classes (default)', () => {
      render(<ActionButton actionId={1007} size="md">Test</ActionButton>);
      expect(screen.getByRole('button')).toHaveClass('px-3', 'py-2');
    });

    it('applies large size classes', () => {
      render(<ActionButton actionId={1007} size="lg">Test</ActionButton>);
      expect(screen.getByRole('button')).toHaveClass('px-4', 'py-3', 'text-lg');
    });
  });

  describe('click behavior', () => {
    it('sends execute command for numeric action ID', () => {
      render(<ActionButton actionId={1007}>Play</ActionButton>);
      fireEvent.click(screen.getByRole('button'));

      expect(mockSendCommand).toHaveBeenCalledTimes(1);
      expect(mockSendCommand).toHaveBeenCalledWith({
        command: 'action/execute',
        params: { commandId: 1007 },
      });
    });

    it('sends executeByName command for string action ID', () => {
      render(<ActionButton actionId="_RS12345">Custom Action</ActionButton>);
      fireEvent.click(screen.getByRole('button'));

      expect(mockSendCommand).toHaveBeenCalledTimes(1);
      expect(mockSendCommand).toHaveBeenCalledWith({
        command: 'action/executeByName',
        params: { name: '_RS12345' },
      });
    });

    it('does not send command when disabled', () => {
      render(<ActionButton actionId={1007} disabled>Play</ActionButton>);
      fireEvent.click(screen.getByRole('button'));

      expect(mockSendCommand).not.toHaveBeenCalled();
    });
  });

  describe('disabled state', () => {
    it('sets disabled attribute when disabled', () => {
      render(<ActionButton actionId={1007} disabled>Play</ActionButton>);
      expect(screen.getByRole('button')).toBeDisabled();
    });

    it('is not disabled by default', () => {
      render(<ActionButton actionId={1007}>Play</ActionButton>);
      expect(screen.getByRole('button')).not.toBeDisabled();
    });
  });
});

describe('ToggleButton', () => {
  beforeEach(() => {
    mockSendCommand.mockClear();
  });

  describe('rendering', () => {
    it('renders children content', () => {
      render(<ToggleButton actionId={40364} isActive={false}>Click</ToggleButton>);
      expect(screen.getByText('Click')).toBeInTheDocument();
    });

    it('renders with title attribute', () => {
      render(<ToggleButton actionId={40364} isActive={false} title="Toggle metronome">Click</ToggleButton>);
      expect(screen.getByTitle('Toggle metronome')).toBeInTheDocument();
    });
  });

  describe('active state styling', () => {
    it('applies inactive classes when not active', () => {
      render(<ToggleButton actionId={40364} isActive={false}>Click</ToggleButton>);
      expect(screen.getByRole('button')).toHaveClass('bg-bg-elevated', 'text-text-tertiary');
    });

    it('applies green active classes when active (default)', () => {
      render(<ToggleButton actionId={40364} isActive={true}>Click</ToggleButton>);
      expect(screen.getByRole('button')).toHaveClass('bg-success-action');
    });

    it('applies blue active classes', () => {
      render(<ToggleButton actionId={40364} isActive={true} activeColor="blue">Click</ToggleButton>);
      expect(screen.getByRole('button')).toHaveClass('bg-primary');
    });

    it('applies yellow active classes', () => {
      render(<ToggleButton actionId={40364} isActive={true} activeColor="yellow">Click</ToggleButton>);
      expect(screen.getByRole('button')).toHaveClass('bg-toggle-yellow');
    });

    it('applies red active classes', () => {
      render(<ToggleButton actionId={40364} isActive={true} activeColor="red">Click</ToggleButton>);
      expect(screen.getByRole('button')).toHaveClass('bg-error-action');
    });

    it('applies purple active classes', () => {
      render(<ToggleButton actionId={40364} isActive={true} activeColor="purple">Click</ToggleButton>);
      expect(screen.getByRole('button')).toHaveClass('bg-accent-region');
    });
  });

  describe('sizes', () => {
    it('applies small size classes', () => {
      render(<ToggleButton actionId={40364} isActive={false} size="sm">Test</ToggleButton>);
      expect(screen.getByRole('button')).toHaveClass('px-2', 'py-1', 'text-sm');
    });

    it('applies medium size classes (default)', () => {
      render(<ToggleButton actionId={40364} isActive={false}>Test</ToggleButton>);
      expect(screen.getByRole('button')).toHaveClass('px-3', 'py-2');
    });

    it('applies large size classes', () => {
      render(<ToggleButton actionId={40364} isActive={false} size="lg">Test</ToggleButton>);
      expect(screen.getByRole('button')).toHaveClass('px-4', 'py-3', 'text-lg');
    });
  });

  describe('click behavior', () => {
    it('sends execute command for numeric action ID', () => {
      render(<ToggleButton actionId={40364} isActive={false}>Click</ToggleButton>);
      fireEvent.click(screen.getByRole('button'));

      expect(mockSendCommand).toHaveBeenCalledTimes(1);
      expect(mockSendCommand).toHaveBeenCalledWith({
        command: 'action/execute',
        params: { commandId: 40364 },
      });
    });

    it('sends executeByName command for string action ID', () => {
      render(<ToggleButton actionId="_RS_TOGGLE" isActive={false}>Click</ToggleButton>);
      fireEvent.click(screen.getByRole('button'));

      expect(mockSendCommand).toHaveBeenCalledWith({
        command: 'action/executeByName',
        params: { name: '_RS_TOGGLE' },
      });
    });

    it('does not send command when disabled', () => {
      render(<ToggleButton actionId={40364} isActive={false} disabled>Click</ToggleButton>);
      fireEvent.click(screen.getByRole('button'));

      expect(mockSendCommand).not.toHaveBeenCalled();
    });
  });

  describe('disabled state', () => {
    it('sets disabled attribute when disabled', () => {
      render(<ToggleButton actionId={40364} isActive={false} disabled>Click</ToggleButton>);
      expect(screen.getByRole('button')).toBeDisabled();
    });
  });
});
