/**
 * InstrumentsView - chord pad pages in portrait
 *
 * Portrait shows the seven chords of the key a page at a time, as many per
 * page as the container's width fits (80px columns, 8px gaps, 12px padding
 * each side, never fewer than two). Every chord must be reachable, and a
 * resize must never leave the view on a page that no longer exists.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { act, fireEvent, render, screen } from '@testing-library/react';

vi.hoisted(() => vi.resetModules());

vi.mock('../../hooks/useReaper', () => ({
  useReaper: () => ({ connected: true, sendCommand: vi.fn(), sendCommandAsync: vi.fn() }),
}));
vi.mock('../../hooks', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../hooks')>()),
  useIsLandscape: () => false,
}));
vi.mock('../../components', () => ({
  ViewHeader: () => null,
  ViewLayout: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));
vi.mock('../../components/Instruments', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../components/Instruments')>()),
  Chords: ({ visibleChords }: { visibleChords?: number[] }) => (
    <div data-testid="chords">{visibleChords?.join(',') ?? 'all'}</div>
  ),
}));

const { InstrumentsView } = await import('./InstrumentsView');

let containerWidth = 0;
let resizeCallbacks: Array<() => void> = [];

class CapturingResizeObserver {
  private readonly callback: () => void;
  constructor(callback: () => void) {
    this.callback = callback;
  }
  observe() {
    resizeCallbacks.push(this.callback);
  }
  unobserve() {}
  disconnect() {
    resizeCallbacks = resizeCallbacks.filter((cb) => cb !== this.callback);
  }
}

const originalResizeObserver = globalThis.ResizeObserver;
const originalClientWidth = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'clientWidth');

function resizeContainer(width: number) {
  containerWidth = width;
  act(() => {
    for (const cb of resizeCallbacks) cb();
  });
}

const visibleChords = () => screen.getByTestId('chords').textContent;
const pageLabel = () => screen.getByText(/^\d+\/\d+$/).textContent;

describe('InstrumentsView chord pages (portrait)', () => {
  beforeEach(() => {
    localStorage.setItem('reamo_instruments_selected', 'chords');
    containerWidth = 0;
    resizeCallbacks = [];
    globalThis.ResizeObserver = CapturingResizeObserver as unknown as typeof ResizeObserver;
    Object.defineProperty(HTMLElement.prototype, 'clientWidth', {
      configurable: true,
      get: () => containerWidth,
    });
  });

  afterEach(() => {
    localStorage.clear();
    globalThis.ResizeObserver = originalResizeObserver;
    if (originalClientWidth) {
      Object.defineProperty(HTMLElement.prototype, 'clientWidth', originalClientWidth);
    }
  });

  it('reaches all seven chords two at a time when the container is narrow', () => {
    render(<InstrumentsView />);

    expect(visibleChords()).toBe('0,1');
    expect(pageLabel()).toBe('1/4');

    const next = screen.getByRole('button', { name: /Next/ });
    fireEvent.click(next);
    expect(visibleChords()).toBe('2,3');
    fireEvent.click(next);
    expect(visibleChords()).toBe('4,5');
    fireEvent.click(next);
    expect(visibleChords()).toBe('6');
    expect(pageLabel()).toBe('4/4');
    expect((next as HTMLButtonElement).disabled).toBe(true);
  });

  it('fits as many chords per page as the container width allows', () => {
    render(<InstrumentsView />);

    // 400px: (400 - 24 + 8) / (80 + 8) = 4.36, so four per page
    resizeContainer(400);
    expect(visibleChords()).toBe('0,1,2,3');
    expect(pageLabel()).toBe('1/2');

    // Wide enough for all seven: one page, no paging buttons
    resizeContainer(1000);
    expect(visibleChords()).toBe('0,1,2,3,4,5,6');
    expect(screen.queryByRole('button', { name: /Next/ })).toBeNull();
  });

  it('moves back to the last page when a resize leaves the current page out of range', () => {
    render(<InstrumentsView />);

    const next = screen.getByRole('button', { name: /Next/ });
    fireEvent.click(next);
    fireEvent.click(next);
    fireEvent.click(next);
    expect(pageLabel()).toBe('4/4');

    resizeContainer(400);
    expect(pageLabel()).toBe('2/2');
    expect(visibleChords()).toBe('4,5,6');
  });
});
