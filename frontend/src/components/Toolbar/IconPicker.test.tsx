/**
 * Tests for IconPicker focus handling
 */

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { LazyIconPicker } from './LazyIconPicker';

describe('IconPicker', () => {
  afterEach(() => {
    cleanup();
  });

  it('blurs the focused search field before the picker is unmounted', async () => {
    const { unmount } = render(<LazyIconPicker onChange={vi.fn()} onClose={vi.fn()} />);
    const search = await screen.findByPlaceholderText('record, marker, guitar...', {}, { timeout: 10000 });
    expect(search).toHaveFocus();
    const connectedAtBlur: boolean[] = [];
    search.addEventListener('blur', () => connectedAtBlur.push(search.isConnected));

    unmount();

    expect(connectedAtBlur).toEqual([true]);
  });
});
