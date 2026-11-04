/**
 * useRecordButton tests.
 *
 * Each gesture fires the event sequence a browser sends to the Record button.
 * A tap toggles recording; a hold sets the next record mode. A stray tap
 * starts a take, so every press that isn't a deliberate tap or hold must send
 * nothing.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, fireEvent, cleanup, act } from '@testing-library/react';

// setup.ts pre-caches modules before vi.mock can intercept.
// resetModules forces re-evaluation so mocks apply to transitive imports.
vi.hoisted(() => vi.resetModules());

const mockSendCommand = vi.fn();

vi.mock('./useReaper', () => ({
  useReaper: () => ({ sendCommand: mockSendCommand }),
}));

import { useRecordButton } from './useRecordButton';
import { useReaperStore } from '../store';
import type { RecordMode } from '../core/types';

type Point = { x: number; y: number };

const AT: Point = { x: 100, y: 100 };

const RECORD = { command: 'transport/record' };
const SET_TIME_SELECTION_PUNCH = { command: 'action/execute', params: { commandId: 40076 } };
const SET_SELECTED_ITEMS_PUNCH = { command: 'action/execute', params: { commandId: 40253 } };
const SET_NORMAL = { command: 'action/execute', params: { commandId: 40252 } };

function RecordProbe() {
  const { handlers } = useRecordButton();
  return (
    <button type="button" {...handlers}>
      record
    </button>
  );
}

function setup(mode: RecordMode = 'normal') {
  act(() => {
    useReaperStore.setState({ recordMode: mode });
  });
  const utils = render(<RecordProbe />);
  return { ...utils, el: utils.getByRole('button') };
}

function sent() {
  return mockSendCommand.mock.calls.map(([cmd]) => cmd as unknown);
}

function pointer(at: Point, pointerType = 'touch', pointerId = 1, extra: Record<string, unknown> = {}) {
  return { pointerId, pointerType, isPrimary: pointerId === 1, clientX: at.x, clientY: at.y, button: 0, ...extra };
}

function touchInit(at: Point, down: boolean) {
  const t = [{ clientX: at.x, clientY: at.y }];
  return { touches: down ? t : [], changedTouches: t };
}

function fingerDown(el: Element, at: Point = AT) {
  fireEvent.pointerDown(el, pointer(at));
  fireEvent.touchStart(el, touchInit(at, true));
}

function fingerMove(el: Element, at: Point) {
  fireEvent.pointerMove(el, pointer(at));
  fireEvent.touchMove(el, touchInit(at, true));
}

/** Lifts the finger. A touch's pointer leaves its target once it lifts. */
function fingerUp(el: Element, at: Point = AT) {
  fireEvent.pointerUp(el, pointer(at));
  fireEvent.pointerLeave(el, pointer(at));
  fireEvent.touchEnd(el, touchInit(at, false));
}

/** The mouse events and click a browser emulates after a finger tap. */
function emulatedMouse(el: Element, at: Point = AT) {
  fireEvent.mouseDown(el, { clientX: at.x, clientY: at.y });
  fireEvent.mouseUp(el, { clientX: at.x, clientY: at.y });
  fireEvent.click(el, { clientX: at.x, clientY: at.y, detail: 1 });
}

function mouseDown(el: Element, extra: Record<string, unknown> = {}, at: Point = AT) {
  const buttons = extra.button === 2 ? 2 : 1;
  fireEvent.pointerDown(el, pointer(at, 'mouse', 1, { buttons, ...extra }));
  fireEvent.mouseDown(el, { clientX: at.x, clientY: at.y, buttons, ...extra });
}

function mouseUp(el: Element, extra: Record<string, unknown> = {}, at: Point = AT) {
  fireEvent.pointerUp(el, pointer(at, 'mouse', 1, { buttons: 0, ...extra }));
  fireEvent.mouseUp(el, { clientX: at.x, clientY: at.y, ...extra });
}

function wait(ms: number) {
  act(() => {
    vi.advanceTimersByTime(ms);
  });
}

describe('useRecordButton', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    mockSendCommand.mockClear();
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  describe('tap toggles recording', () => {
    it('a finger tap sends one record toggle, not a second for the emulated mouse events', () => {
      const { el } = setup();

      fingerDown(el);
      wait(100);
      fingerUp(el);
      emulatedMouse(el);
      wait(1000);

      expect(sent()).toEqual([RECORD]);
    });

    it('a mouse click sends one record toggle', () => {
      const { el } = setup();

      mouseDown(el);
      mouseUp(el);
      fireEvent.click(el, { detail: 1 });

      expect(sent()).toEqual([RECORD]);
    });

    it('a release just before the hold time is a tap, not a mode change', () => {
      const { el } = setup();

      fingerDown(el);
      wait(299);
      fingerUp(el);
      wait(1000);

      expect(sent()).toEqual([RECORD]);
    });

    it('Enter or Space on the focused button, with no pointer press, toggles recording', () => {
      const { el } = setup();

      fireEvent.click(el, { detail: 0 });

      expect(sent()).toEqual([RECORD]);
    });

    it("a held Enter's auto-repeats are cancelled, so they click the button no further", () => {
      // A browser clicks a focused button on each Enter keydown, repeats
      // included; cancelling a keydown cancels its click.
      const { el } = setup();

      const firstNotPrevented = fireEvent.keyDown(el, { key: 'Enter', repeat: false });
      const repeatNotPrevented = fireEvent.keyDown(el, { key: 'Enter', repeat: true });

      expect(firstNotPrevented).toBe(true);
      expect(repeatNotPrevented).toBe(false);
    });
  });

  describe('hold sets the next record mode', () => {
    it.each<[RecordMode, unknown]>([
      ['normal', SET_TIME_SELECTION_PUNCH],
      ['timeSelection', SET_SELECTED_ITEMS_PUNCH],
      ['selectedItems', SET_NORMAL],
    ])('a 300 ms hold in %s mode sets the next mode, and its release toggles nothing', (mode, next) => {
      const { el } = setup(mode);

      fingerDown(el);
      wait(300);
      fingerUp(el);
      emulatedMouse(el);

      expect(sent()).toEqual([next]);
    });

    it('a hold steps from the mode REAPER reports when it fires, not when the press began', () => {
      const { el } = setup('normal');

      fingerDown(el);
      wait(150);
      // REAPER's mode changes mid-hold (set there, or by an earlier hold
      // whose state update lands now).
      act(() => {
        useReaperStore.setState({ recordMode: 'timeSelection' });
      });
      wait(150);
      fingerUp(el);

      expect(sent()).toEqual([SET_SELECTED_ITEMS_PUNCH]);
    });
  });

  describe('presses that are neither send nothing', () => {
    it('a mouse pressed elsewhere and released over the button sends nothing', () => {
      const { el } = setup();

      // The button went down outside, and the mouse was dragged in.
      fireEvent.pointerOver(el, pointer(AT, 'mouse', 1, { buttons: 1 }));
      fireEvent.pointerEnter(el, pointer(AT, 'mouse', 1, { buttons: 1 }));
      fireEvent.pointerMove(el, pointer(AT, 'mouse', 1, { buttons: 1 }));
      mouseUp(el);
      wait(1000);

      expect(sent()).toEqual([]);
    });

    it('a mouse that leaves the button mid-press and comes back to release sends nothing', () => {
      const { el } = setup();

      mouseDown(el);
      wait(100);
      fireEvent.pointerLeave(el, pointer({ x: 300, y: 100 }, 'mouse', 1, { buttons: 1 }));
      wait(100);
      fireEvent.pointerEnter(el, pointer(AT, 'mouse', 1, { buttons: 1 }));
      mouseUp(el);
      wait(1000);

      expect(sent()).toEqual([]);
    });

    it('a quick right-click sends nothing', () => {
      const { el } = setup();

      mouseDown(el, { button: 2 });
      mouseUp(el, { button: 2 });
      fireEvent.contextMenu(el, { button: 2 });
      wait(1000);

      expect(sent()).toEqual([]);
    });

    it('a held right-click does not change the record mode', () => {
      const { el } = setup();

      mouseDown(el, { button: 2 });
      fireEvent.contextMenu(el, { button: 2 });
      wait(1000);
      mouseUp(el, { button: 2 });

      expect(sent()).toEqual([]);
    });

    it('a mouse Ctrl+click, which opens the context menu on macOS, sends nothing', () => {
      const { el } = setup();

      mouseDown(el, { ctrlKey: true });
      fireEvent.contextMenu(el, { ctrlKey: true });
      mouseUp(el, { ctrlKey: true });
      wait(1000);

      expect(sent()).toEqual([]);
    });

    it('a finger that drags across the button and lifts on it sends nothing', () => {
      const { el } = setup();

      fingerDown(el);
      wait(50);
      fingerMove(el, { x: AT.x + 30, y: AT.y });
      wait(50);
      fingerUp(el, { x: AT.x + 30, y: AT.y });
      wait(1000);

      expect(sent()).toEqual([]);
    });

    it('a finger that lifts beyond the tolerance with no move reported before it sends nothing', () => {
      const { el } = setup();

      fingerDown(el);
      wait(50);
      fingerUp(el, { x: AT.x + 30, y: AT.y });
      wait(1000);

      expect(sent()).toEqual([]);
    });

    it('a finger that drifts beyond the tolerance while held does not change the record mode', () => {
      const { el } = setup();

      fingerDown(el);
      wait(100);
      fingerMove(el, { x: AT.x, y: AT.y + 30 });
      wait(1000);
      fingerUp(el, { x: AT.x, y: AT.y + 30 });

      expect(sent()).toEqual([]);
    });

    it('a touch the browser cancels sends nothing', () => {
      const { el } = setup();

      fingerDown(el);
      wait(100);
      fireEvent.pointerCancel(el, pointer(AT));
      fireEvent.pointerLeave(el, pointer(AT));
      wait(1000);

      expect(sent()).toEqual([]);
    });

    it('a mouse held while the window loses focus (Cmd/Alt-Tab) neither changes the mode nor toggles on release', () => {
      const { el } = setup();

      mouseDown(el);
      wait(100);
      act(() => {
        window.dispatchEvent(new Event('blur'));
      });
      wait(1000);
      mouseUp(el);
      fireEvent.click(el, { clientX: AT.x, clientY: AT.y, detail: 1 });

      expect(sent()).toEqual([]);
    });
  });
});
