/**
 * Tests for useLayoutContext — which navigation layout a viewport size gets,
 * and that the on-screen keyboard doesn't change it.
 */

import { describe, it, expect, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useLayoutContext } from './useLayoutContext';

function resizeTo(width: number, height: number) {
  act(() => {
    Object.defineProperty(window, 'innerWidth', { value: width, configurable: true });
    Object.defineProperty(window, 'innerHeight', { value: height, configurable: true });
    window.dispatchEvent(new Event('resize'));
  });
}

function focusTextField(type = 'text'): HTMLInputElement {
  const input = document.createElement('input');
  input.type = type;
  document.body.appendChild(input);
  input.focus();
  return input;
}

afterEach(() => {
  (document.activeElement as HTMLElement | null)?.blur();
  document.body.innerHTML = '';
});

describe('useLayoutContext', () => {
  it('puts navigation at the bottom of a phone held upright', () => {
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    expect(result.current.navPosition).toBe('bottom');
  });

  it('moves navigation to the side when the phone turns to landscape', () => {
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    resizeTo(780, 412);
    expect(result.current.navPosition).toBe('side');
  });

  it('keeps the layout when the keyboard shrinks an upright phone below its width', () => {
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    focusTextField();
    resizeTo(412, 400);
    expect(result.current.navPosition).toBe('bottom');
  });

  it('keeps the layout when the keyboard opens for a textarea', () => {
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    const area = document.createElement('textarea');
    document.body.appendChild(area);
    area.focus();
    resizeTo(412, 400);
    expect(result.current.navPosition).toBe('bottom');
  });

  it('follows a height-only resize when no text field has focus', () => {
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    resizeTo(412, 400);
    expect(result.current.navPosition).toBe('side');
  });

  it('follows a height-only resize when the focused control opens no keyboard', () => {
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    focusTextField('checkbox');
    resizeTo(412, 400);
    expect(result.current.navPosition).toBe('side');
  });

  it('follows a rotation while a text field has focus', () => {
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    focusTextField();
    resizeTo(780, 300);
    expect(result.current.navPosition).toBe('side');
  });
});
