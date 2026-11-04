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
  pointerClick(el, at);
}

/** A click that ends a pointer press: its detail is the click count. */
function pointerClick(el: Element, at: Point = AT) {
  fireEvent.click(el, { clientX: at.x, clientY: at.y, detail: 1 });
}

/** The browser takes the touch over for a scroll. */
function fingerCancel(el: Element, at: Point = AT, pointerId = 1) {
  fireEvent.pointerCancel(el, pointer(at, 'touch', pointerId));
  fireEvent.pointerLeave(el, pointer(at, 'touch', pointerId));
  fireEvent.touchCancel(el, touchInit(at, false));
}

function mouseDown(el: Element, extra: Record<string, unknown> = {}, at: Point = AT) {
  const buttons = extra.button === 2 ? 2 : 1;
  fireEvent.pointerDown(el, pointer(at, 'mouse', 1, { buttons, ...extra }));
  fireEvent.mouseDown(el, { clientX: at.x, clientY: at.y, ...extra });
}

function mouseUp(el: Element, extra: Record<string, unknown> = {}, at: Point = AT) {
  fireEvent.pointerUp(el, pointer(at, 'mouse', 1, extra));
  fireEvent.mouseUp(el, { clientX: at.x, clientY: at.y, ...extra });
}

let visibility: DocumentVisibilityState = 'visible';

/** Sets document.visibilityState and fires visibilitychange, as a browser does. */
function setVisibility(state: DocumentVisibilityState) {
  visibility = state;
  act(() => {
    document.dispatchEvent(new Event('visibilitychange'));
  });
}

function wait(ms: number) {
  act(() => {
    vi.advanceTimersByTime(ms);
  });
}

describe('useLongPress', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    visibility = 'visible';
    vi.spyOn(document, 'visibilityState', 'get').mockImplementation(() => visibility);
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
    vi.restoreAllMocks();
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
      pointerClick(el);

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

    it('a release beyond the tolerance with no move before it is not a tap', () => {
      const { el, onTap } = setup();

      fingerDown(el);
      fingerUp(el, { x: AT.x, y: AT.y + 30 });

      expect(onTap).not.toHaveBeenCalled();
    });

    it('a click with no pointer behind it, from a keyboard or screen reader, is a tap', () => {
      const { el, onTap, onLongPress } = setup();

      fireEvent.click(el, { detail: 0 });

      expect(onTap).toHaveBeenCalledTimes(1);
      expect(onLongPress).not.toHaveBeenCalled();
    });

    it('a pointer tap followed by a click with no detail taps once', () => {
      const { el, onTap } = setup();

      fingerDown(el);
      fingerUp(el);
      fireEvent.click(el, { detail: 0 });

      expect(onTap).toHaveBeenCalledTimes(1);
    });

    it('a click with no detail after a pointer tap and its own click is a tap', () => {
      const { el, onTap } = setup();

      fingerDown(el);
      fingerUp(el);
      emulatedMouse(el);
      fireEvent.click(el, { detail: 0 });

      expect(onTap).toHaveBeenCalledTimes(2);
    });

    it('a click with no detail after a cancelled press is a tap, even soon after an earlier tap', () => {
      const { el, onTap } = setup();

      // A tap whose click never came, then a press the browser cancels.
      fingerDown(el);
      fingerUp(el);
      fingerDown(el);
      fingerCancel(el);
      fireEvent.click(el, { detail: 0 });

      expect(onTap).toHaveBeenCalledTimes(2);
    });

    it('a click with no detail long after a tap whose click never came is a tap', () => {
      const { el, onTap } = setup();

      fingerDown(el);
      fingerUp(el);
      wait(600);
      fireEvent.click(el, { detail: 0 });

      expect(onTap).toHaveBeenCalledTimes(2);
    });

    it('a mouse-type press that never reports its button down still taps', () => {
      // A screen reader's emulated pointer can report no buttons.
      const { el, onTap } = setup();

      fireEvent.pointerDown(el, pointer(AT, 'mouse', 1, { buttons: 0 }));
      fireEvent.pointerMove(el, pointer(AT, 'mouse', 1, { buttons: 0 }));
      fireEvent.pointerUp(el, pointer(AT, 'mouse', 1, { buttons: 0 }));

      expect(onTap).toHaveBeenCalledTimes(1);
    });

    it('a press does not take focus from a text field', () => {
      const { el } = setup();

      const down = fireEvent.mouseDown(el);

      // fireEvent returns false when the default action was prevented.
      expect(down).toBe(false);
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
      pointerClick(el);

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

    it('a still hold that the browser cancels fires nothing, even when an up follows', () => {
      const { el, onTap, onLongPress } = setup();

      fingerDown(el);
      fingerMove(el, { x: AT.x, y: AT.y - 8 });
      fireEvent.pointerCancel(el, pointer({ x: AT.x, y: AT.y - 8 }));
      wait(1000);
      fireEvent.pointerUp(el, pointer({ x: AT.x, y: AT.y - 8 }));

      expect(onLongPress).not.toHaveBeenCalled();
      expect(onTap).not.toHaveBeenCalled();
    });

    it('a mouse whose primary button comes up while another stays down ends the hold', () => {
      const { el, onTap, onLongPress } = setup();

      mouseDown(el);
      // Right button joins, then the left lifts: chorded buttons send moves.
      fireEvent.pointerMove(el, pointer(AT, 'mouse', 1, { buttons: 3 }));
      fireEvent.pointerMove(el, pointer(AT, 'mouse', 1, { buttons: 2 }));
      wait(1000);
      fireEvent.pointerUp(el, pointer(AT, 'mouse', 1, { button: 2, buttons: 0 }));

      expect(onLongPress).not.toHaveBeenCalled();
      expect(onTap).not.toHaveBeenCalled();
    });

    it("a touch hold's context menu event is suppressed and the hold goes on", () => {
      // Android raises it for a finger held still, near the hold's duration.
      const { el, onTap, onLongPress } = setup();

      fingerDown(el);
      wait(300);
      const notPrevented = fireEvent.contextMenu(el);
      wait(100);

      expect(notPrevented).toBe(false);
      expect(onLongPress).toHaveBeenCalledTimes(1);
      expect(onTap).not.toHaveBeenCalled();
    });

    it("a touch's context menu event after its long press is suppressed too", () => {
      const { el, onLongPress } = setup();

      fingerDown(el);
      wait(400);

      expect(fireEvent.contextMenu(el)).toBe(false);
      expect(onLongPress).toHaveBeenCalledTimes(1);
    });

    it('a mouse opening the context menu mid-hold ends it', () => {
      const { el, onTap, onLongPress } = setup();

      mouseDown(el);
      wait(200);
      fireEvent.contextMenu(el);
      wait(1000);
      mouseUp(el);

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

      // The first finger's moves and lift neither end the second press nor
      // tap for it.
      fingerMove(el, { x: AT.x + 100, y: AT.y }, 1);
      fingerUp(el, { x: AT.x + 100, y: AT.y }, 1);
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

    it('the window losing focus mid-hold ends the press: no long press, and no tap on the release', () => {
      // Switching apps with Cmd/Alt-Tab while the mouse is down.
      const { el, onTap, onLongPress } = setup();

      mouseDown(el);
      wait(200);
      act(() => {
        window.dispatchEvent(new Event('blur'));
      });
      wait(1000);
      mouseUp(el);
      pointerClick(el);

      expect(onLongPress).not.toHaveBeenCalled();
      expect(onTap).not.toHaveBeenCalled();
    });

    it('the page being hidden mid-hold ends the press: no long press, and no tap on the release', () => {
      // A phone locked, or the browser switched away from, with a finger down.
      const { el, onTap, onLongPress } = setup();

      fingerDown(el);
      wait(200);
      setVisibility('hidden');
      wait(1000);
      setVisibility('visible');
      fingerUp(el);
      emulatedMouse(el);

      expect(onLongPress).not.toHaveBeenCalled();
      expect(onTap).not.toHaveBeenCalled();
    });

    it('the page becoming visible mid-hold leaves the press running', () => {
      const { el, onLongPress } = setup();

      fingerDown(el);
      wait(200);
      setVisibility('visible');
      wait(200);

      expect(onLongPress).toHaveBeenCalledTimes(1);
    });

    it('a press after the window lost focus works', () => {
      const { el, onTap, onLongPress } = setup();

      mouseDown(el);
      act(() => {
        window.dispatchEvent(new Event('blur'));
      });
      mouseUp(el);
      mouseDown(el);
      mouseUp(el);
      fingerDown(el);
      wait(400);

      expect(onTap).toHaveBeenCalledTimes(1);
      expect(onLongPress).toHaveBeenCalledTimes(1);
    });

    it('listens for focus loss and hiding only while a press is under way', () => {
      const add = vi.spyOn(window, 'addEventListener');
      const addDoc = vi.spyOn(document, 'addEventListener');
      const remove = vi.spyOn(window, 'removeEventListener');
      const removeDoc = vi.spyOn(document, 'removeEventListener');
      const { el } = setup();
      const added = () =>
        add.mock.calls.filter(([type]) => type === 'blur').length +
        addDoc.mock.calls.filter(([type]) => type === 'visibilitychange').length;
      const removed = () =>
        remove.mock.calls.filter(([type]) => type === 'blur').length +
        removeDoc.mock.calls.filter(([type]) => type === 'visibilitychange').length;

      expect(added()).toBe(0);
      fingerDown(el);
      expect(added()).toBe(2);
      fingerUp(el);
      expect(removed()).toBe(2);
      fingerDown(el);
      wait(400);
      expect(removed()).toBe(4);
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

  describe('keyboard', () => {
    // A browser clicks a focused button on each Enter keydown, auto-repeats
    // included, and cancelling a keydown cancels the click it would make.
    // jsdom makes no click from a key, so these check which keydowns are
    // cancelled; e2e/long-press-keys-focus.spec.ts checks the clicks.

    it("a held Enter's or Space's first keydown is let through, so one press is one tap", () => {
      const { el } = setup();

      expect(fireEvent.keyDown(el, { key: 'Enter', repeat: false })).toBe(true);
      expect(fireEvent.keyDown(el, { key: ' ', repeat: false })).toBe(true);
    });

    it("a held Enter's key repeats are cancelled, so they click the element no further", () => {
      const { el } = setup();

      fireEvent.keyDown(el, { key: 'Enter', repeat: false });
      expect(fireEvent.keyDown(el, { key: 'Enter', repeat: true })).toBe(false);
      expect(fireEvent.keyDown(el, { key: 'Enter', repeat: true })).toBe(false);
    });

    it("a held Space's key repeats are cancelled too", () => {
      const { el } = setup();

      fireEvent.keyDown(el, { key: ' ', repeat: false });
      expect(fireEvent.keyDown(el, { key: ' ', repeat: true })).toBe(false);
    });

    it("other keys' repeats are left alone", () => {
      const { el } = setup();

      expect(fireEvent.keyDown(el, { key: 'ArrowRight', repeat: true })).toBe(true);
      expect(fireEvent.keyDown(el, { key: 'a', repeat: true })).toBe(true);
    });

    it('key repeats from a field inside the element are left alone', () => {
      function Wrapper() {
        const { handlers } = useLongPress({ onTap: () => {} });
        return (
          <div {...handlers}>
            <input aria-label="name" />
          </div>
        );
      }
      const { getByRole } = render(<Wrapper />);
      const field = getByRole('textbox');

      expect(fireEvent.keyDown(field, { key: ' ', repeat: true })).toBe(true);
      expect(fireEvent.keyDown(field, { key: 'Enter', repeat: true })).toBe(true);
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
