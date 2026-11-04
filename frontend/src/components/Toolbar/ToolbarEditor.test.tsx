/**
 * Tests for ToolbarEditor
 *
 * Focus: a focused text field must be blurred while it's still on the page
 * before the editor or its action search pane removes it, so a phone keyboard
 * closes the normal way.
 *
 * Escape closes only the topmost dialog, and the delete confirmation's reset
 * timer doesn't outlive the editor.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react';
import { useReaperStore } from '../../store';
import type { ToolbarAction } from '../../store/slices/toolbarSlice';
import { ToolbarEditor } from './ToolbarEditor';

const EXISTING_ACTION: ToolbarAction = {
  id: 'tb_1',
  label: 'Play',
  type: 'reaper_action',
  actionId: '40044',
  sectionId: 0,
};

/** Records whether the element was still on the page each time it blurred. */
function trackBlur(el: HTMLElement): boolean[] {
  const connectedAtBlur: boolean[] = [];
  el.addEventListener('blur', () => connectedAtBlur.push(el.isConnected));
  return connectedAtBlur;
}

function renderEditor() {
  return render(
    <ToolbarEditor action={null} isNew onClose={vi.fn()} onSave={vi.fn()} onDelete={vi.fn()} />
  );
}

describe('ToolbarEditor', () => {
  beforeEach(() => {
    useReaperStore.setState({
      actionCache: [{ commandId: 40044, sectionId: 0, name: 'Transport: Play/stop', isToggle: false, namedId: null }],
    });
  });

  afterEach(() => {
    cleanup();
    useReaperStore.setState({ actionCache: [] });
  });

  it('blurs the action search field while it is still on the page when Back leaves the search', () => {
    renderEditor();
    fireEvent.click(screen.getByText('Search and Select Action...'));
    const search = screen.getByPlaceholderText(/Search by name/);
    expect(search).toHaveFocus();
    const connectedAtBlur = trackBlur(search);

    fireEvent.click(screen.getByText('Back'));

    expect(connectedAtBlur).toEqual([true]);
  });

  it('blurs the focused field before the editor is unmounted', () => {
    const { unmount } = renderEditor();
    const label = screen.getByPlaceholderText(/label/i);
    label.focus();
    const connectedAtBlur = trackBlur(label);

    unmount();

    expect(connectedAtBlur).toEqual([true]);
  });

  describe('Escape', () => {
    it('closes only the icon picker when the picker is open over the editor', async () => {
      const onClose = vi.fn();
      render(<ToolbarEditor action={null} isNew onClose={onClose} onSave={vi.fn()} onDelete={vi.fn()} />);
      fireEvent.click(screen.getByText('Select icon...'));
      await screen.findByPlaceholderText('record, marker, guitar...', {}, { timeout: 10000 });

      fireEvent.keyDown(window, { key: 'Escape' });

      expect(screen.queryByPlaceholderText('record, marker, guitar...')).toBeNull();
      expect(onClose).not.toHaveBeenCalled();
      expect(screen.getByText('Add Toolbar Button')).toBeInTheDocument();
    });

    it('closes the editor when no picker is open over it', () => {
      const onClose = vi.fn();
      render(<ToolbarEditor action={null} isNew onClose={onClose} onSave={vi.fn()} onDelete={vi.fn()} />);

      fireEvent.keyDown(window, { key: 'Escape' });

      expect(onClose).toHaveBeenCalledTimes(1);
    });
  });

  describe('delete confirmation', () => {
    beforeEach(() => {
      vi.useFakeTimers();
    });

    afterEach(() => {
      vi.useRealTimers();
    });

    function renderExisting() {
      const utils = render(
        <ToolbarEditor action={EXISTING_ACTION} isNew={false} onClose={vi.fn()} onSave={vi.fn()} onDelete={vi.fn()} />
      );
      // Let the dialog's own mount-time focus timer run so only the
      // confirmation's timer can be pending afterwards.
      act(() => {
        vi.runOnlyPendingTimers();
      });
      return utils;
    }

    it('returns to Delete 3 s after the first tap', () => {
      renderExisting();
      fireEvent.click(screen.getByText('Delete'));
      expect(screen.getByText('Confirm?')).toBeInTheDocument();

      act(() => {
        vi.advanceTimersByTime(3000);
      });

      expect(screen.getByText('Delete')).toBeInTheDocument();
    });

    it('leaves no reset timer pending once the editor is closed', () => {
      const { unmount } = renderExisting();
      fireEvent.click(screen.getByText('Delete'));

      unmount();

      expect(vi.getTimerCount()).toBe(0);
    });
  });
});
