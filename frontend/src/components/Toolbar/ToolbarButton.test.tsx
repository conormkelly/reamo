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
});
