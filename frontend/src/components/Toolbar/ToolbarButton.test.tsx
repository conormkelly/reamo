/**
 * Tests for ToolbarButton long-press timing
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react';
import type { ReactNode } from 'react';
import { ReaperContext } from '../../hooks/useReaper';
import type { UseReaperConnectionReturn } from '../../hooks/useReaperConnection';
import type { ToolbarAction } from '../../store/slices/toolbarSlice';
import { ToolbarButton } from './ToolbarButton';

// The test setup already loads ToolbarButton through the store's view
// registry, so the connection comes from its context, not a module mock.
const connection = { sendCommand: vi.fn() } as unknown as UseReaperConnectionReturn;
function withConnection({ children }: { children: ReactNode }) {
  return <ReaperContext.Provider value={connection}>{children}</ReaperContext.Provider>;
}

const ACTION: ToolbarAction = {
  id: 'tb_1',
  label: 'Play',
  type: 'reaper_action',
  actionId: '40044',
  sectionId: 0,
};

describe('ToolbarButton', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it('reports a long press once the hold lasts long enough', () => {
    const onLongPress = vi.fn();
    render(<ToolbarButton action={ACTION} editMode={false} onEdit={vi.fn()} onLongPress={onLongPress} />, { wrapper: withConnection });

    fireEvent.pointerDown(screen.getByTitle('Play'));
    act(() => {
      vi.advanceTimersByTime(1000);
    });

    expect(onLongPress).toHaveBeenCalledTimes(1);
  });

  it('does not report a long press for a short tap', () => {
    const onLongPress = vi.fn();
    render(<ToolbarButton action={ACTION} editMode={false} onEdit={vi.fn()} onLongPress={onLongPress} />, { wrapper: withConnection });

    const button = screen.getByTitle('Play');
    fireEvent.pointerDown(button);
    act(() => {
      vi.advanceTimersByTime(100);
    });
    fireEvent.pointerUp(button);
    act(() => {
      vi.advanceTimersByTime(1000);
    });

    expect(onLongPress).not.toHaveBeenCalled();
  });

  it('reports one long press when a second pointer down arrives mid-hold', () => {
    const onLongPress = vi.fn();
    render(<ToolbarButton action={ACTION} editMode={false} onEdit={vi.fn()} onLongPress={onLongPress} />, { wrapper: withConnection });

    const button = screen.getByTitle('Play');
    fireEvent.pointerDown(button);
    fireEvent.pointerDown(button);
    act(() => {
      vi.advanceTimersByTime(1000);
    });

    expect(onLongPress).toHaveBeenCalledTimes(1);
  });

  it('opens the editor on the first tap in edit mode after a long press that ended without a click', () => {
    const onEdit = vi.fn();
    const { rerender } = render(
      <ToolbarButton action={ACTION} editMode={false} onEdit={onEdit} onLongPress={vi.fn()} />,
      { wrapper: withConnection }
    );
    const button = screen.getByTitle('Play');

    // The hold enters edit mode, then the finger slides off: no click follows.
    fireEvent.pointerDown(button);
    act(() => {
      vi.advanceTimersByTime(1000);
    });
    fireEvent.pointerLeave(button);
    rerender(<ToolbarButton action={ACTION} editMode onEdit={onEdit} onLongPress={vi.fn()} />);

    fireEvent.pointerDown(button);
    fireEvent.pointerUp(button);
    fireEvent.click(button);

    expect(onEdit).toHaveBeenCalledTimes(1);
  });

  it('does not report a long press after the button is removed mid-hold', () => {
    const onLongPress = vi.fn();
    const { unmount } = render(
      <ToolbarButton action={ACTION} editMode={false} onEdit={vi.fn()} onLongPress={onLongPress} />,
      { wrapper: withConnection }
    );

    fireEvent.pointerDown(screen.getByTitle('Play'));
    unmount();
    vi.advanceTimersByTime(1000);

    expect(onLongPress).not.toHaveBeenCalled();
  });

  describe('presses that are neither a tap nor a hold', () => {
    type Point = { x: number; y: number };
    const AT: Point = { x: 100, y: 100 };

    function pointer(at: Point, pointerType = 'mouse', extra: Record<string, unknown> = {}) {
      return { pointerId: 1, pointerType, isPrimary: true, clientX: at.x, clientY: at.y, button: 0, buttons: 1, ...extra };
    }

    function setup(editMode = false) {
      const onLongPress = vi.fn();
      const onEdit = vi.fn();
      vi.mocked(connection.sendCommand).mockClear();
      render(<ToolbarButton action={ACTION} editMode={editMode} onEdit={onEdit} onLongPress={onLongPress} />, {
        wrapper: withConnection,
      });
      return { button: screen.getByTitle('Play'), onLongPress, onEdit };
    }

    it('a right-button hold does not enter edit mode', () => {
      const { button, onLongPress } = setup();

      fireEvent.pointerDown(button, pointer(AT, 'mouse', { button: 2, buttons: 2 }));
      act(() => {
        vi.advanceTimersByTime(1000);
      });

      expect(onLongPress).not.toHaveBeenCalled();
    });

    it('a hold ended by the window losing focus does not enter edit mode', () => {
      const { button, onLongPress } = setup();

      fireEvent.pointerDown(button, pointer(AT));
      act(() => {
        window.dispatchEvent(new Event('blur'));
      });
      act(() => {
        vi.advanceTimersByTime(1000);
      });

      expect(onLongPress).not.toHaveBeenCalled();
    });

    it('a press dragged past the move tolerance does not enter edit mode', () => {
      const { button, onLongPress } = setup();

      fireEvent.pointerDown(button, pointer(AT));
      fireEvent.pointerMove(button, pointer({ x: AT.x + 20, y: AT.y }));
      act(() => {
        vi.advanceTimersByTime(1000);
      });

      expect(onLongPress).not.toHaveBeenCalled();
    });

    it('a held Enter runs the action once: its key repeats are cancelled, which cancels their clicks', () => {
      const { button } = setup();

      const first = fireEvent.keyDown(button, { key: 'Enter' });
      const repeat = fireEvent.keyDown(button, { key: 'Enter', repeat: true });

      expect(first).toBe(true);
      expect(repeat).toBe(false);
    });

    it('a tap runs the action once', () => {
      const { button } = setup();

      fireEvent.pointerDown(button, pointer(AT, 'touch'));
      fireEvent.pointerUp(button, pointer(AT, 'touch', { buttons: 0 }));
      fireEvent.click(button, { detail: 1 });

      expect(connection.sendCommand).toHaveBeenCalledTimes(1);
      expect(connection.sendCommand).toHaveBeenCalledWith({
        command: 'action/execute',
        params: { commandId: 40044 },
      });
    });

    it('Enter or a screen reader activation (a click with no pointer) runs the action once', () => {
      const { button } = setup();

      fireEvent.click(button, { detail: 0 });

      expect(connection.sendCommand).toHaveBeenCalledTimes(1);
    });

    it('a draggable button keeps its mousedown default, which a browser needs to start a drag', () => {
      const noop = () => {};
      const dragProps = {
        draggable: true,
        onDragStart: noop,
        onDragOver: noop,
        onDrop: noop,
        onDragEnd: noop,
        onTouchStart: noop,
        onTouchMove: noop,
        onTouchEnd: noop,
      };
      render(<ToolbarButton action={ACTION} editMode onEdit={vi.fn()} dragProps={dragProps} />, {
        wrapper: withConnection,
      });

      expect(fireEvent.mouseDown(screen.getByTitle('Play'))).toBe(true);
    });

    it('a button that is not draggable does not take focus when pressed', () => {
      const { button } = setup();

      expect(fireEvent.mouseDown(button)).toBe(false);
    });

    it('a tap in edit mode opens the editor and runs nothing', () => {
      const { button, onEdit, onLongPress } = setup(true);

      fireEvent.pointerDown(button, pointer(AT, 'touch'));
      act(() => {
        vi.advanceTimersByTime(1000);
      });
      fireEvent.pointerUp(button, pointer(AT, 'touch', { buttons: 0 }));
      fireEvent.click(button, { detail: 1 });

      expect(onEdit).toHaveBeenCalledTimes(1);
      expect(onLongPress).not.toHaveBeenCalled();
      expect(connection.sendCommand).not.toHaveBeenCalled();
    });
  });
});
