/**
 * useGestureGuid keeps a drag on the GUID it began with when the GUID at the
 * modal's track index changes mid-drag, and takes the new one for the next drag.
 */

import { describe, it, expect } from 'vitest';
import { renderHook } from '@testing-library/react';
import { useGestureGuid } from './useGestureGuid';

describe('useGestureGuid', () => {
  it('keeps the GUID locked at begin() until end(), whatever the track at the index becomes', () => {
    const { result, rerender } = renderHook(({ guid }) => useGestureGuid(guid), {
      initialProps: { guid: '{GUITAR}' as string | undefined },
    });

    expect(result.current.begin()).toBe('{GUITAR}');
    rerender({ guid: '{VOCALS}' }); // a track was inserted above
    expect(result.current.current()).toBe('{GUITAR}');
    expect(result.current.end()).toBe('{GUITAR}');

    // Unlocked: values follow the track now shown, and end() has nothing to end.
    expect(result.current.current()).toBe('{VOCALS}');
    expect(result.current.end()).toBeNull();

    // The next drag locks the track now shown.
    expect(result.current.begin()).toBe('{VOCALS}');
    rerender({ guid: '{CLICK}' });
    expect(result.current.current()).toBe('{VOCALS}');
  });

  it('locks nothing when the track has no GUID yet', () => {
    const { result } = renderHook(() => useGestureGuid(undefined));
    expect(result.current.begin()).toBeNull();
    expect(result.current.current()).toBeUndefined();
    expect(result.current.end()).toBeNull();
  });
});
