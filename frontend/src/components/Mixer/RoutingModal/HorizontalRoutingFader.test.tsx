/**
 * HorizontalRoutingFader tests: a level or pan drag ends however the
 * browser ends it, so its gesture is always closed and later moves change
 * nothing.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, screen, fireEvent, cleanup, act } from '@testing-library/react';
import { useReaperStore } from '../../../store';
import { HorizontalRoutingFader } from './HorizontalRoutingFader';

const callbacks = {
  onVolumeChange: vi.fn(),
  onVolumeGestureStart: vi.fn(),
  onVolumeGestureEnd: vi.fn(),
  onPanChange: vi.fn(),
  onPanGestureStart: vi.fn(),
  onPanGestureEnd: vi.fn(),
  onMuteToggle: vi.fn(),
  onModeToggle: vi.fn(),
  onVolumeDoubleTap: vi.fn(),
  onPanDoubleTap: vi.fn(),
};

function renderFader() {
  render(
    <HorizontalRoutingFader volume={1} pan={0} muted={false} mode={0} label="Bus" colorScheme="send" {...callbacks} />
  );
}

const ENDS: [string, () => void][] = [
  ['a touch is cancelled', () => fireEvent.touchCancel(document)],
  ['the window loses focus', () => fireEvent.blur(window)],
  [
    'the page is hidden',
    () => {
      Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
      fireEvent(document, new Event('visibilitychange'));
      Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
    },
  ],
];

describe('HorizontalRoutingFader drag end', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useReaperStore.setState({ mixerLocked: false });
  });

  afterEach(() => {
    cleanup();
  });

  describe.each([
    ['level', 'Level - double-tap to reset to 0dB', callbacks.onVolumeGestureEnd, callbacks.onVolumeChange],
    ['pan', 'Pan - double-tap to center', callbacks.onPanGestureEnd, callbacks.onPanChange],
  ])('%s', (_control, title, onEnd, onChange) => {
    it.each(ENDS)('ends the drag when %s', (_what, end) => {
      renderFader();
      fireEvent.touchStart(screen.getByTitle(title), { touches: [{ clientX: 10, clientY: 10 }] });
      const changes = onChange.mock.calls.length;

      act(() => end());

      expect(onEnd).toHaveBeenCalledTimes(1);
      fireEvent.touchMove(document, { touches: [{ clientX: 50, clientY: 10 }] });
      expect(onChange).toHaveBeenCalledTimes(changes);
    });
  });
});
