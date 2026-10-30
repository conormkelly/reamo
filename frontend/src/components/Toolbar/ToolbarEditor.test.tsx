/**
 * Tests for ToolbarEditor focus handling
 *
 * A focused text field must be blurred while it's still on the page before
 * the editor or its action search pane removes it, so a phone keyboard
 * closes the normal way.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup } from '@testing-library/react';
import { useReaperStore } from '../../store';
import { ToolbarEditor } from './ToolbarEditor';

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
});
