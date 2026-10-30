/**
 * Tests for useLayoutContext — which navigation layout a device and viewport
 * get, and that nothing but turning the device changes it on a phone.
 */

import { describe, it, expect, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { classifyLayout, useLayoutContext } from './useLayoutContext';

type OrientationType = 'portrait-primary' | 'landscape-primary';

/** A stand-in for screen.orientation that tests can turn. */
class FakeScreenOrientation extends EventTarget {
  type: OrientationType = 'portrait-primary';
}

let orientation: FakeScreenOrientation | undefined;

function holdDevice(type: OrientationType | 'unsupported') {
  act(() => {
    if (type === 'unsupported') {
      orientation = undefined;
    } else {
      orientation ??= new FakeScreenOrientation();
      orientation.type = type;
    }
    Object.defineProperty(screen, 'orientation', { value: orientation, configurable: true });
  });
}

/** Turn the device: the orientation's change event, with no window resize yet. */
function turnDevice(type: OrientationType) {
  act(() => {
    orientation!.type = type;
    orientation!.dispatchEvent(new Event('change'));
  });
}

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
  orientation = undefined;
});

describe('classifyLayout', () => {
  // [device, width, height, expected navPosition]
  const cases: [string, number, number, 'bottom' | 'side', string][] = [
    ['portrait', 412, 839, 'bottom', 'upright phone'],
    ['portrait', 412, 380, 'bottom', 'upright phone with the keyboard up'],
    ['portrait', 390, 334, 'bottom', 'upright phone whose browser left the viewport at keyboard height'],
    ['landscape', 839, 412, 'side', 'phone on its side'],
    ['landscape', 1280, 440, 'side', 'landscape tablet with the keyboard up'],
    ['landscape', 320, 1024, 'bottom', 'landscape iPad running the app in a narrow Slide Over window'],
    ['landscape', 1200, 450, 'side', 'desktop window dragged short'],
    ['landscape', 1366, 1024, 'bottom', 'landscape tablet'],
    ['unknown', 839, 412, 'side', 'browser without screen.orientation, wide short viewport'],
    ['unknown', 412, 839, 'bottom', 'browser without screen.orientation, tall viewport'],
  ];

  it.each(cases)('device %s at %ix%i gets %s navigation (%s)', (device, width, height, expected) => {
    const layout = classifyLayout(
      { width, height },
      device as 'portrait' | 'landscape' | 'unknown',
    );
    expect(layout.navPosition).toBe(expected);
    expect(layout.isLandscapeConstrained).toBe(expected === 'side');
  });

  it('an upright device is never landscape, however short the viewport', () => {
    expect(classifyLayout({ width: 390, height: 334 }, 'portrait').isLandscape).toBe(false);
  });

  it('a device on its side is landscape at any height', () => {
    expect(classifyLayout({ width: 1366, height: 1024 }, 'landscape').isLandscape).toBe(true);
  });
});

describe('useLayoutContext', () => {
  it('puts navigation at the bottom of a phone held upright', () => {
    holdDevice('portrait-primary');
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    expect(result.current.navPosition).toBe('bottom');
  });

  it('moves navigation to the side when the phone turns to landscape', () => {
    holdDevice('portrait-primary');
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    turnDevice('landscape-primary');
    resizeTo(780, 412);
    expect(result.current.navPosition).toBe('side');
  });

  it('settles on the side rail when the orientation change arrives after the resize', () => {
    holdDevice('portrait-primary');
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    resizeTo(780, 412);
    turnDevice('landscape-primary');
    expect(result.current.navPosition).toBe('side');
  });

  it('keeps an upright phone at the bottom when its viewport is left short with nothing focused', () => {
    holdDevice('portrait-primary');
    resizeTo(390, 664);
    const { result } = renderHook(() => useLayoutContext());
    resizeTo(390, 334);
    expect(result.current.navPosition).toBe('bottom');
  });

  it('keeps the layout when the keyboard shrinks a landscape tablet below the side-rail height', () => {
    holdDevice('landscape-primary');
    resizeTo(1280, 800);
    const { result } = renderHook(() => useLayoutContext());
    focusTextField();
    resizeTo(1280, 440);
    expect(result.current.navPosition).toBe('bottom');
  });

  it('keeps the layout when the keyboard opens for a textarea', () => {
    holdDevice('landscape-primary');
    resizeTo(1280, 800);
    const { result } = renderHook(() => useLayoutContext());
    const area = document.createElement('textarea');
    document.body.appendChild(area);
    area.focus();
    resizeTo(1280, 440);
    expect(result.current.navPosition).toBe('bottom');
  });

  it('follows a height-only resize of a desktop window with nothing focused', () => {
    holdDevice('landscape-primary');
    resizeTo(1280, 800);
    const { result } = renderHook(() => useLayoutContext());
    resizeTo(1280, 440);
    expect(result.current.navPosition).toBe('side');
  });

  it('follows a height-only resize when the focused control opens no keyboard', () => {
    holdDevice('landscape-primary');
    resizeTo(1280, 800);
    const { result } = renderHook(() => useLayoutContext());
    focusTextField('checkbox');
    resizeTo(1280, 440);
    expect(result.current.navPosition).toBe('side');
  });

  it('follows a rotation while a text field has focus', () => {
    holdDevice('portrait-primary');
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    focusTextField();
    turnDevice('landscape-primary');
    resizeTo(780, 300);
    expect(result.current.navPosition).toBe('side');
  });

  it('falls back to the viewport shape when the browser has no screen.orientation', () => {
    holdDevice('unsupported');
    resizeTo(412, 780);
    const { result } = renderHook(() => useLayoutContext());
    resizeTo(780, 412);
    expect(result.current.navPosition).toBe('side');
  });

  it('gives a consumer mounted while the keyboard is up the same layout as one mounted before', () => {
    holdDevice('landscape-primary');
    resizeTo(1280, 800);
    const first = renderHook(() => useLayoutContext());
    focusTextField();
    resizeTo(1280, 440);
    const second = renderHook(() => useLayoutContext());
    expect(second.result.current.navPosition).toBe(first.result.current.navPosition);
    expect(second.result.current.viewport).toEqual(first.result.current.viewport);
  });
});
