/**
 * useTransportAnimation - Subscribe to 60fps interpolated transport position
 *
 * Uses the TransportAnimationEngine for smooth client-side interpolation
 * between server updates. Designed for direct DOM manipulation patterns
 * using useLayoutEffect.
 *
 * @example
 * function Playhead() {
 *   const elementRef = useRef<HTMLDivElement>(null);
 *
 *   useTransportAnimation((state) => {
 *     if (elementRef.current) {
 *       elementRef.current.style.left = `${state.position * 10}px`;
 *     }
 *   });
 *
 *   return <div ref={elementRef} className="playhead" />;
 * }
 */

import { useLayoutEffect } from 'react';
import { transportEngine, type TransportSubscriber } from '../core/TransportAnimationEngine';

/**
 * Subscribe to transport animation updates at 60fps
 *
 * @param callback - Called with interpolated transport state on each frame.
 *                   Should update DOM directly via refs, not trigger React re-renders.
 * @param deps - Optional dependency array (callback is re-subscribed when deps change)
 */
export function useTransportAnimation(
  callback: TransportSubscriber,
  deps: React.DependencyList = []
): void {
  useLayoutEffect(() => {
    return transportEngine.subscribe(callback);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}

/**
 * Get a one-time snapshot of current transport animation state
 * Useful for initialization or non-animated reads
 */
export function getTransportAnimationState() {
  return transportEngine.getState();
}
