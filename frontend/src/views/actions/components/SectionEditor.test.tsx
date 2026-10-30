/**
 * Tests for SectionEditor focus handling
 */

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/react';
import { SectionEditor } from './SectionEditor';

describe('SectionEditor', () => {
  afterEach(() => {
    cleanup();
  });

  it('blurs the focused name field before the editor is unmounted', () => {
    const { unmount } = render(<SectionEditor section={null} onSave={vi.fn()} onClose={vi.fn()} />);
    const name = screen.getByPlaceholderText('e.g., Transport, FX, Navigation');
    expect(name).toHaveFocus();
    const connectedAtBlur: boolean[] = [];
    name.addEventListener('blur', () => connectedAtBlur.push(name.isConnected));

    unmount();

    expect(connectedAtBlur).toEqual([true]);
  });
});
