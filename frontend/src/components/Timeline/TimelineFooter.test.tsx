/**
 * TimelineFooter - the selection mode button's presses
 *
 * A tap toggles selection mode and a hold opens manual selection input. A
 * press that is neither (a release with no press on the button, a
 * right-click, a finger dragged across it, a hold ended by the window losing
 * focus) does nothing.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react';
import { TimelineFooter } from './TimelineFooter';

type Point = { x: number; y: number };
const AT: Point = { x: 100, y: 100 };

function pointer(at: Point, pointerType = 'touch', extra: Record<string, unknown> = {}) {
  return { pointerId: 1, pointerType, isPrimary: true, clientX: at.x, clientY: at.y, button: 0, buttons: 1, ...extra };
}

function wait(ms: number) {
  act(() => {
    vi.advanceTimersByTime(ms);
  });
}

function setup() {
  const onSelectionModeToggle = vi.fn();
  const onSelectionLongPress = vi.fn();
  render(
    <TimelineFooter
      onPrevMarker={vi.fn()}
      onNextMarker={vi.fn()}
      followPlayhead={false}
      onFollowPlayheadToggle={vi.fn()}
      selectionModeActive={false}
      onSelectionModeToggle={onSelectionModeToggle}
      onSelectionLongPress={onSelectionLongPress}
      visibleDuration={30}
      onZoomIn={vi.fn()}
      onZoomOut={vi.fn()}
      onFitToContent={vi.fn()}
    />
  );
  return { button: screen.getByTestId('selection-toggle'), onSelectionModeToggle, onSelectionLongPress };
}

describe('TimelineFooter selection mode button', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    cleanup();
    vi.useRealTimers();
  });

  it('a tap toggles selection mode once', () => {
    const { button, onSelectionModeToggle, onSelectionLongPress } = setup();

    fireEvent.pointerDown(button, pointer(AT));
    wait(100);
    fireEvent.pointerUp(button, pointer(AT, 'touch', { buttons: 0 }));
    fireEvent.click(button, { detail: 1 });
    wait(1000);

    expect(onSelectionModeToggle).toHaveBeenCalledTimes(1);
    expect(onSelectionLongPress).not.toHaveBeenCalled();
  });

  it('a hold opens manual input and its release does not toggle', () => {
    const { button, onSelectionModeToggle, onSelectionLongPress } = setup();

    fireEvent.pointerDown(button, pointer(AT));
    wait(500);
    fireEvent.pointerUp(button, pointer(AT, 'touch', { buttons: 0 }));
    fireEvent.click(button, { detail: 1 });

    expect(onSelectionLongPress).toHaveBeenCalledTimes(1);
    expect(onSelectionModeToggle).not.toHaveBeenCalled();
  });

  it('Enter or a screen reader activation (a click with no pointer) toggles selection mode', () => {
    const { button, onSelectionModeToggle } = setup();

    fireEvent.click(button, { detail: 0 });

    expect(onSelectionModeToggle).toHaveBeenCalledTimes(1);
  });

  it('a release with no press on the button does not toggle', () => {
    const { button, onSelectionModeToggle } = setup();

    fireEvent.pointerUp(button, pointer(AT, 'mouse', { buttons: 0 }));

    expect(onSelectionModeToggle).not.toHaveBeenCalled();
  });

  it('a press that leaves the button and comes back does not toggle on release', () => {
    const { button, onSelectionModeToggle } = setup();

    fireEvent.pointerDown(button, pointer(AT, 'mouse'));
    fireEvent.pointerLeave(button, pointer({ x: AT.x, y: AT.y - 80 }, 'mouse'));
    fireEvent.pointerUp(button, pointer(AT, 'mouse', { buttons: 0 }));

    expect(onSelectionModeToggle).not.toHaveBeenCalled();
  });

  it('a right-click neither toggles nor opens manual input', () => {
    const { button, onSelectionModeToggle, onSelectionLongPress } = setup();

    fireEvent.pointerDown(button, pointer(AT, 'mouse', { button: 2, buttons: 2 }));
    wait(500);
    fireEvent.pointerUp(button, pointer(AT, 'mouse', { button: 2, buttons: 0 }));

    expect(onSelectionModeToggle).not.toHaveBeenCalled();
    expect(onSelectionLongPress).not.toHaveBeenCalled();
  });

  it('a finger dragged across the button neither toggles nor opens manual input', () => {
    const { button, onSelectionModeToggle, onSelectionLongPress } = setup();

    fireEvent.pointerDown(button, pointer(AT));
    fireEvent.pointerMove(button, pointer({ x: AT.x + 20, y: AT.y }));
    wait(500);
    fireEvent.pointerUp(button, pointer({ x: AT.x + 20, y: AT.y }, 'touch', { buttons: 0 }));

    expect(onSelectionModeToggle).not.toHaveBeenCalled();
    expect(onSelectionLongPress).not.toHaveBeenCalled();
  });

  it('a hold ended by the window losing focus neither toggles nor opens manual input', () => {
    const { button, onSelectionModeToggle, onSelectionLongPress } = setup();

    fireEvent.pointerDown(button, pointer(AT, 'mouse'));
    act(() => {
      window.dispatchEvent(new Event('blur'));
    });
    wait(500);
    fireEvent.pointerUp(button, pointer(AT, 'mouse', { buttons: 0 }));

    expect(onSelectionModeToggle).not.toHaveBeenCalled();
    expect(onSelectionLongPress).not.toHaveBeenCalled();
  });
});
