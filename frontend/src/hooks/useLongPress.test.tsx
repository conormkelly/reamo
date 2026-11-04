/**
 * useLongPress tests.
 *
 * Each gesture fires the event sequence a browser sends: pointer events, the
 * touch events beside them for a finger, and for a finger tap the emulated
 * mouse events and the click that follow it. The handlers are spread on a
 * button, as the hook's callers do.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, fireEvent, cleanup, act } from '@testing-library/react';
import { useLongPress, type UseLongPressOptions } from './useLongPress';

type Point = { x: number; y: number };

const AT: Point = { x: 100, y: 100 };

function Probe(props: UseLongPressOptions) {
  const { handlers } = useLongPress(props);
  return (
    <button type="button" {...handlers}>
      hold me
    </button>
  );
}

function setup(options: Partial<UseLongPressOptions> = {}) {
  const onTap = vi.fn();
  const onLongPress = vi.fn();
  const props = { onTap, onLongPress, duration: 400, ...options };
  const utils = render(<Probe {...props} />);
  const el = utils.getByRole('button');
  return { ...utils, el, onTap, onLongPress };
}

function pointer(at: Point, pointerType = 'touch', pointerId = 1, extra: Record<string, unknown> = {}) {
  return { pointerId, pointerType, isPrimary: pointerId === 1, clientX: at.x, clientY: at.y, button: 0, ...extra };
}

function touchInit(at: Point, down: boolean) {
  const t = [{ clientX: at.x, clientY: at.y }];
  return { touches: down ? t : [], changedTouches: t };
}

function fingerDown(el: Element, at: Point = AT, pointerId = 1) {
  fireEvent.pointerDown(el, pointer(at, 'touch', pointerId));
  fireEvent.touchStart(el, touchInit(at, true));
}

function fingerMove(el: Element, at: Point, pointerId = 1) {
  fireEvent.pointerMove(el, pointer(at, 'touch', pointerId));
  fireEvent.touchMove(el, touchInit(at, true));
}

/** Lifts the finger. A touch's pointer leaves its target once it lifts. */
function fingerUp(el: Element, at: Point = AT, pointerId = 1) {
  fireEvent.pointerUp(el, pointer(at, 'touch', pointerId));
  fireEvent.pointerLeave(el, pointer(at, 'touch', pointerId));
  fireEvent.touchEnd(el, touchInit(at, false));
}

/** The mouse events and click a browser emulates after a finger tap. */
function emulatedMouse(el: Element, at: Point = AT) {
  fireEvent.mouseDown(el, { clientX: at.x, clientY: at.y });
  fireEvent.mouseUp(el, { clientX: at.x, clientY: at.y });
  fireEvent.click(el, { clientX: at.x, clientY: at.y });
}

/** The browser takes the touch over for a scroll. */
function fingerCancel(el: Element, at: Point = AT, pointerId = 1) {
  fireEvent.pointerCancel(el, pointer(at, 'touch', pointerId));
  fireEvent.pointerLeave(el, pointer(at, 'touch', pointerId));
  fireEvent.touchCancel(el, touchInit(at, false));
}

function mouseDown(el: Element, extra: Record<string, unknown> = {}, at: Point = AT) {
  fireEvent.pointerDown(el, pointer(at, 'mouse', 1, extra));
  fireEvent.mouseDown(el, { clientX: at.x, clientY: at.y, ...extra });
}

function mouseUp(el: Element, extra: Record<string, unknown> = {}, at: Point = AT) {
  fireEvent.pointerUp(el, pointer(at, 'mouse', 1, extra));
  fireEvent.mouseUp(el, { clientX: at.x, clientY: at.y, ...extra });
}

function wait(ms: number) {
  act(() => {
    vi.advanceTimersByTime(ms);
  });
}

describe('useLongPress', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  describe('tap', () => {
    it('a finger tap fires onTap once, not again for the emulated mouse events', () => {
      const { el, onTap, onLongPress } = setup();

      fingerDown(el);
      wait(100);
      fingerUp(el);
      emulatedMouse(el);
      wait(1000);

      expect(onTap).toHaveBeenCalledTimes(1);
      expect(onLongPress).not.toHaveBeenCalled();
    });

    it('a finger tap fires onTap once when the emulated mouse events come after a click delay', () => {
      const { el, onTap } = setup();

      fingerDown(el);
      wait(100);
      fingerUp(el);
      // A browser that waits to rule out a double-tap zoom sends them late.
      wait(350);
      emulatedMouse(el);

      expect(onTap).toHaveBeenCalledTimes(1);
    });

    it('a mouse click fires onTap once', () => {
      const { el, onTap } = setup();

      mouseDown(el);
      mouseUp(el);
      fireEvent.click(el);

      expect(onTap).toHaveBeenCalledTimes(1);
    });

    it('a pen tap fires onTap once', () => {
      const { el, onTap } = setup();

      fireEvent.pointerDown(el, pointer(AT, 'pen'));
      fireEvent.pointerUp(el, pointer(AT, 'pen'));

      expect(onTap).toHaveBeenCalledTimes(1);
    });

    it('a release with no press on the element is not a tap', () => {
      const { el, onTap } = setup();

      // The button went down elsewhere and came up over this element.
      mouseUp(el);

      expect(onTap).not.toHaveBeenCalled();
    });

    it('two taps in a row fire onTap twice', () => {
      const { el, onTap } = setup();

      fingerDown(el);
      fingerUp(el);
      emulatedMouse(el);
      wait(50);
      fingerDown(el);
      fingerUp(el);
      emulatedMouse(el);

      expect(onTap).toHaveBeenCalledTimes(2);
    });

    it('a long hold without onLongPress is still a tap on release', () => {
      const { el, onTap } = setup({ onLongPress: undefined });

      fingerDown(el);
      wait(2000);
      fingerUp(el);

      expect(onTap).toHaveBeenCalledTimes(1);
    });
  });

  describe('long press', () => {
    it('a still finger held for the duration fires onLongPress once and no tap', () => {
      const { el, onTap, onLongPress } = setup();

      fingerDown(el);
      wait(399);
      expect(onLongPress).not.toHaveBeenCalled();
      wait(1);
      expect(onLongPress).toHaveBeenCalledTimes(1);

      fingerUp(el);
      wait(1000);

      expect(onLongPress).toHaveBeenCalledTimes(1);
      expect(onTap).not.toHaveBeenCalled();
    });

    it('a mouse held for the duration fires onLongPress and no tap', () => {
      const { el, onTap, onLongPress } = setup({ duration: 500 });

      mouseDown(el);
      wait(500);
      mouseUp(el);
      fireEvent.click(el);

      expect(onLongPress).toHaveBeenCalledTimes(1);
      expect(onTap).not.toHaveBeenCalled();
    });

    it('a finger drifting within the tolerance still holds', () => {
      const { el, onLongPress } = setup();

      fingerDown(el);
      fingerMove(el, { x: AT.x + 6, y: AT.y + 6 });
      wait(400);

      expect(onLongPress).toHaveBeenCalledTimes(1);
    });

    it('runs the onLongPress of the latest render, not the one the press began with', () => {
      // Callers' callbacks read state such as the mixer lock, which can
      // change while a finger is down.
      const first = vi.fn();
      const second = vi.fn();
      const { getByRole, rerender } = render(<Probe onLongPress={first} duration={400} />);

      fingerDown(getByRole('button'));
      wait(200);
      rerender(<Probe onLongPress={second} duration={400} />);
      wait(200);

      expect(first).not.toHaveBeenCalled();
      expect(second).toHaveBeenCalledTimes(1);
    });
  });

  describe('cancelling', () => {
    it('a hold that the browser turns into a scroll fires nothing', () => {
      const { el, onTap, onLongPress } = setup();

      fingerDown(el);
      fingerMove(el, { x: AT.x, y: AT.y - 8 });
      fingerMove(el, { x: AT.x, y: AT.y - 20 });
      fingerCancel(el, { x: AT.x, y: AT.y - 20 });
      wait(1000);

      expect(onLongPress).not.toHaveBeenCalled();
      expect(onTap).not.toHaveBeenCalled();
    });

    it('a finger that drifts past the tolerance and stays down fires nothing', () => {
      // An element with touch-action: none never gets a pointercancel: the
      // drift itself has to end the hold.
      const { el, onTap, onLongPress } = setup();

      fingerDown(el);
      fingerMove(el, { x: AT.x + 15, y: AT.y });
      wait(1000);
      fingerUp(el, { x: AT.x + 15, y: AT.y });

      expect(onLongPress).not.toHaveBeenCalled();
      expect(onTap).not.toHaveBeenCalled();
    });

    it('a quick swipe across the element is not a tap', () => {
      const { el, onTap, onLongPress } = setup();

      fingerDown(el);
      fingerMove(el, { x: AT.x, y: AT.y + 30 });
      wait(100);
      fingerUp(el, { x: AT.x, y: AT.y + 30 });
      wait(1000);

      expect(onTap).not.toHaveBeenCalled();
      expect(onLongPress).not.toHaveBeenCalled();
    });

    it('a mouse that leaves the element mid-hold fires nothing', () => {
      const { el, onTap, onLongPress } = setup();

      mouseDown(el);
      wait(200);
      fireEvent.pointerLeave(el, pointer(AT, 'mouse'));
      fireEvent.mouseOut(el, { relatedTarget: document.body });
      wait(1000);
      mouseUp(el);

      expect(onTap).not.toHaveBeenCalled();
      expect(onLongPress).not.toHaveBeenCalled();
    });

    it('a new press restarts the hold, and the old pointer no longer counts', () => {
      const { el, onTap, onLongPress } = setup();

      fingerDown(el, AT, 1);
      wait(300);
      fingerDown(el, { x: AT.x + 40, y: AT.y }, 2);
      wait(200);
      expect(onLongPress).not.toHaveBeenCalled();

      // The first finger's lift is not the second press's tap.
      fireEvent.pointerUp(el, pointer(AT, 'touch', 1));
      expect(onTap).not.toHaveBeenCalled();

      wait(200);
      expect(onLongPress).toHaveBeenCalledTimes(1);
    });

    it('unmounting mid-hold fires nothing', () => {
      const { el, unmount, onTap, onLongPress } = setup();

      fingerDown(el);
      wait(200);
      unmount();
      wait(1000);

      expect(onLongPress).not.toHaveBeenCalled();
      expect(onTap).not.toHaveBeenCalled();
    });

    it('a press after a cancelled one works', () => {
      const { el, onTap } = setup();

      fingerDown(el);
      fingerCancel(el);
      fingerDown(el);
      fingerUp(el);

      expect(onTap).toHaveBeenCalledTimes(1);
    });
  });

  describe('presses that open the context menu', () => {
    it('a right-button press fires nothing', () => {
      const { el, onTap, onLongPress } = setup();

      mouseDown(el, { button: 2 });
      wait(1000);
      mouseUp(el, { button: 2 });

      expect(onTap).not.toHaveBeenCalled();
      expect(onLongPress).not.toHaveBeenCalled();
    });

    it('a mouse Ctrl+click fires nothing', () => {
      const { el, onTap, onLongPress } = setup();

      mouseDown(el, { ctrlKey: true });
      wait(1000);
      mouseUp(el, { ctrlKey: true });

      expect(onTap).not.toHaveBeenCalled();
      expect(onLongPress).not.toHaveBeenCalled();
    });
  });

  it('returns the same handlers across renders', () => {
    const seen: unknown[] = [];
    function Capture() {
      const { handlers } = useLongPress({ onTap: () => {}, onLongPress: () => {} });
      seen.push(handlers);
      return null;
    }
    const { rerender } = render(<Capture />);
    rerender(<Capture />);

    expect(seen).toHaveLength(2);
    expect(seen[1]).toBe(seen[0]);
  });
});
