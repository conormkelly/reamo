/**
 * Tests for BottomSheet focus handling
 */

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, act } from '@testing-library/react';
import { BottomSheet } from './BottomSheet';

describe('BottomSheet focus', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('leaves focus on a field that autofocuses as the sheet opens', () => {
    vi.useFakeTimers();
    render(
      <BottomSheet isOpen onClose={vi.fn()}>
        <input aria-label="Search" autoFocus />
      </BottomSheet>
    );
    act(() => vi.runAllTimers());
    expect(screen.getByLabelText('Search')).toHaveFocus();
  });

  it('focuses the sheet when nothing inside it takes focus', () => {
    vi.useFakeTimers();
    render(
      <BottomSheet isOpen onClose={vi.fn()}>
        <p>Content</p>
      </BottomSheet>
    );
    act(() => vi.runAllTimers());
    expect(screen.getByRole('dialog')).toHaveFocus();
  });

  it('blurs the focused field as soon as the sheet starts closing', () => {
    vi.useFakeTimers();
    const sheet = (isOpen: boolean) => (
      <BottomSheet isOpen={isOpen} onClose={vi.fn()}>
        <input aria-label="Search" autoFocus />
      </BottomSheet>
    );
    const { rerender } = render(sheet(true));
    act(() => vi.runAllTimers());
    const input = screen.getByLabelText('Search');

    rerender(sheet(false));

    // The sheet is still on the page for its exit animation.
    expect(input).toBeInTheDocument();
    expect(input).not.toHaveFocus();
  });
});
