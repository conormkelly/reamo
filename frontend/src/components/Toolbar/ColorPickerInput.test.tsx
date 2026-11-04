/**
 * Tests for ColorPickerInput's tap-to-open and hold-to-reset.
 *
 * Each gesture fires the event sequence a browser sends: pointer events,
 * the touch events beside them for a finger, and for a tap the emulated
 * mouse events and the click that follow a touch. The swatch's hidden colour
 * input covers it, so every event targets the input.
 *
 * "Opens the picker" means a click reached the input without being
 * cancelled: that is what makes the browser show its colour picker.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, fireEvent, cleanup, act } from '@testing-library/react';
import { ColorPickerInput } from './ColorPickerInput';

const DEFAULT = '#ffffff';
const CUSTOM = '#ff0000';
const AT = { x: 100, y: 100 };

type Point = { x: number; y: number };

function renderSwatch(value = CUSTOM) {
  const onChange = vi.fn();
  const utils = render(
    <ColorPickerInput label="Icon" value={value} onChange={onChange} defaultValue={DEFAULT} />
  );
  const input = utils.container.querySelector('input[type="color"]') as HTMLInputElement;

  let pickerOpens = 0;
  const countOpen = (e: Event) => {
    if (e.target === input && !e.defaultPrevented) pickerOpens++;
  };
  // Bubble phase on the document runs after React's own handlers.
  document.addEventListener('click', countOpen);
  const stopCounting = () => document.removeEventListener('click', countOpen);

  return { ...utils, onChange, input, pickerOpens: () => pickerOpens, stopCounting };
}

function pointer(at: Point, pointerId = 1, pointerType = 'touch') {
  return { pointerId, pointerType, isPrimary: pointerId === 1, clientX: at.x, clientY: at.y, button: 0 };
}

function touch(at: Point) {
  return { touches: [{ clientX: at.x, clientY: at.y }], changedTouches: [{ clientX: at.x, clientY: at.y }] };
}

function fingerDown(el: Element, at: Point = AT, pointerId = 1) {
  fireEvent.pointerDown(el, pointer(at, pointerId));
  fireEvent.touchStart(el, touch(at));
}

function fingerMove(el: Element, at: Point) {
  fireEvent.pointerMove(el, pointer(at));
  fireEvent.touchMove(el, touch(at));
}

/** Lifts the finger, then the emulated mouse events and click a touch is followed by. */
function fingerUpWithClick(el: Element, at: Point = AT) {
  fireEvent.pointerUp(el, pointer(at));
  fireEvent.pointerLeave(el, pointer(at));
  fireEvent.touchEnd(el, { touches: [], changedTouches: [{ clientX: at.x, clientY: at.y }] });
  fireEvent.mouseDown(el, { clientX: at.x, clientY: at.y });
  fireEvent.mouseUp(el, { clientX: at.x, clientY: at.y });
  fireEvent.click(el, { clientX: at.x, clientY: at.y });
}

function fingerCancel(el: Element, at: Point = AT) {
  fireEvent.pointerCancel(el, pointer(at));
  fireEvent.pointerLeave(el, pointer(at));
  fireEvent.touchCancel(el, { touches: [], changedTouches: [{ clientX: at.x, clientY: at.y }] });
}

function hold(ms: number) {
  act(() => {
    vi.advanceTimersByTime(ms);
  });
}

describe('ColorPickerInput', () => {
  let stopCounting: (() => void) | undefined;

  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    stopCounting?.();
    stopCounting = undefined;
    cleanup();
    vi.useRealTimers();
  });

  function setup(value?: string) {
    const swatch = renderSwatch(value);
    stopCounting = swatch.stopCounting;
    return swatch;
  }

  describe('tap', () => {
    it('opens the picker once for a finger tap', () => {
      const { input, onChange, pickerOpens } = setup();

      fingerDown(input);
      hold(100);
      fingerUpWithClick(input);

      expect(pickerOpens()).toBe(1);
      expect(onChange).not.toHaveBeenCalled();
    });

    it('opens the picker once for a mouse click', () => {
      const { input, pickerOpens } = setup();

      fireEvent.pointerDown(input, pointer(AT, 1, 'mouse'));
      fireEvent.mouseDown(input);
      fireEvent.pointerUp(input, pointer(AT, 1, 'mouse'));
      fireEvent.mouseUp(input);
      fireEvent.click(input);

      expect(pickerOpens()).toBe(1);
    });

    it('opens the picker on release after a long hold on a swatch already at its default', () => {
      const { input, onChange, pickerOpens } = setup(DEFAULT);

      fingerDown(input);
      hold(1000);
      fingerUpWithClick(input);

      expect(onChange).not.toHaveBeenCalled();
      expect(pickerOpens()).toBe(1);
    });
  });

  describe('hold to reset', () => {
    it('resets to the default once the hold lasts 500 ms, and the release does not open the picker', () => {
      const { input, onChange, pickerOpens } = setup();

      fingerDown(input);
      hold(500);
      fingerUpWithClick(input);

      expect(onChange).toHaveBeenCalledTimes(1);
      expect(onChange).toHaveBeenCalledWith(DEFAULT);
      expect(pickerOpens()).toBe(0);
    });

    it('still resets when the finger only jitters within a few pixels', () => {
      const { input, onChange } = setup();

      fingerDown(input);
      fingerMove(input, { x: AT.x + 3, y: AT.y + 2 });
      hold(500);

      expect(onChange).toHaveBeenCalledWith(DEFAULT);
    });

    it('does not reset when the finger moves away from where it pressed', () => {
      const { input, onChange } = setup();

      fingerDown(input);
      fingerMove(input, { x: AT.x, y: AT.y + 30 });
      hold(1000);

      expect(onChange).not.toHaveBeenCalled();
    });

    it('does not reset when the browser cancels the touch', () => {
      const { input, onChange } = setup();

      fingerDown(input);
      hold(100);
      fingerCancel(input);
      hold(1000);

      expect(onChange).not.toHaveBeenCalled();
    });

    it('does not reset after a release when a second press started mid-hold', () => {
      const { input, onChange } = setup();

      fingerDown(input, AT, 1);
      fingerDown(input, AT, 2);
      hold(100);
      fireEvent.pointerUp(input, pointer(AT, 2));
      fireEvent.touchEnd(input, { touches: [], changedTouches: [{ clientX: AT.x, clientY: AT.y }] });
      hold(1000);

      expect(onChange).not.toHaveBeenCalled();
    });

    it('does not reset when the mouse leaves the swatch mid-hold', () => {
      const { input, onChange } = setup();

      fireEvent.pointerDown(input, pointer(AT, 1, 'mouse'));
      fireEvent.mouseDown(input);
      hold(100);
      fireEvent.pointerLeave(input, pointer(AT, 1, 'mouse'));
      fireEvent.mouseLeave(input);
      hold(1000);

      expect(onChange).not.toHaveBeenCalled();
    });

    it('does not reset after the swatch is removed mid-hold', () => {
      const { input, onChange, unmount } = setup();

      fingerDown(input);
      unmount();
      vi.advanceTimersByTime(1000);

      expect(onChange).not.toHaveBeenCalled();
    });

    it('opens the picker on the next tap after a reset whose touch was cancelled', () => {
      const { input, onChange, pickerOpens } = setup();

      fingerDown(input);
      hold(500);
      fingerCancel(input);
      expect(onChange).toHaveBeenCalledTimes(1);

      fingerDown(input);
      hold(100);
      fingerUpWithClick(input);

      expect(pickerOpens()).toBe(1);
    });
  });
});
