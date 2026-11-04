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
