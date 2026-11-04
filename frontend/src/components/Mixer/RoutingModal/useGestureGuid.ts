import { useMemo, useRef } from 'react';

export interface GestureGuid {
  /** Lock the track's GUID for a drag starting now; returns it (null when the track has none). */
  begin: () => string | null;
  /** The GUID to address a value by: the drag's locked GUID, else the track's current one. */
  current: () => string | undefined;
  /** End the drag; returns the GUID it was locked to. */
  end: () => string | null;
}

/**
 * The track GUID one routing control's drag is addressed by. The routing
 * modal follows a track index, so if a track is inserted, deleted or moved
 * above it mid-drag, the index (and the GUID useTrack returns for it) changes
 * to another track. Locking the GUID at gesture start keeps the drag's
 * gesture/start, every value and gesture/end on the track the drag began on,
 * as Fader.tsx does with its gestureGuidRef.
 */
export function useGestureGuid(guid: string | undefined): GestureGuid {
  const locked = useRef<string | null>(null);
  return useMemo(
    () => ({
      begin: () => {
        locked.current = guid ?? null;
        return locked.current;
      },
      current: () => locked.current ?? guid,
      end: () => {
        const g = locked.current;
        locked.current = null;
        return g;
      },
    }),
    [guid]
  );
}
