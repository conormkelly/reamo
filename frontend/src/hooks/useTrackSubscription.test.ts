/**
 * Tests for createRangeSubscription — pure helper for building range subscriptions.
 */

import { describe, it, expect } from 'vitest';
import { createRangeSubscription } from './useTrackSubscription';

describe('createRangeSubscription', () => {
  it('creates range subscription with default buffer', () => {
    const sub = createRangeSubscription(5, 15);
    expect(sub.mode).toBe('range');
    expect(sub).toEqual({ mode: 'range', start: 0, end: 20 });
  });

  it('applies custom buffer', () => {
    const sub = createRangeSubscription(10, 20, 3);
    expect(sub).toEqual({ mode: 'range', start: 7, end: 23 });
  });

  it('clamps start to 0', () => {
    const sub = createRangeSubscription(2, 10, 10);
    expect(sub).toEqual({ mode: 'range', start: 0, end: 20 });
  });

  it('handles zero buffer', () => {
    const sub = createRangeSubscription(5, 10, 0);
    expect(sub).toEqual({ mode: 'range', start: 5, end: 10 });
  });

  it('handles single-item range', () => {
    const sub = createRangeSubscription(0, 0, 5);
    expect(sub).toEqual({ mode: 'range', start: 0, end: 5 });
  });
});
