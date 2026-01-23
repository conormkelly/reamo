/**
 * usePortalPosition - Calculate position for portaled dropdowns/popovers
 *
 * When elements are portaled to document.body, they lose their relative
 * positioning context. This hook calculates absolute coordinates based
 * on the trigger element's position.
 *
 * @example
 * const triggerRef = useRef<HTMLButtonElement>(null);
 * const { position, updatePosition } = usePortalPosition(triggerRef, isOpen);
 *
 * <button ref={triggerRef}>Open</button>
 * {isOpen && (
 *   <Portal>
 *     <div style={{ position: 'fixed', top: position.top, left: position.left }}>
 *       Dropdown content
 *     </div>
 *   </Portal>
 * )}
 */

import { useState, useEffect, useCallback, type RefObject } from 'react';

export interface PortalPosition {
  top: number;
  left: number;
  /** Trigger element width (useful for matching dropdown width) */
  triggerWidth: number;
  /** Trigger element height */
  triggerHeight: number;
}

export type PortalPlacement = 'bottom-start' | 'bottom-end' | 'top-start' | 'top-end';

export interface UsePortalPositionOptions {
  /** Where to place the dropdown relative to trigger. Default: 'bottom-start' */
  placement?: PortalPlacement;
  /** Offset from trigger in pixels. Default: 4 */
  offset?: number;
}

const DEFAULT_POSITION: PortalPosition = {
  top: 0,
  left: 0,
  triggerWidth: 0,
  triggerHeight: 0,
};

export function usePortalPosition(
  triggerRef: RefObject<HTMLElement | null>,
  isOpen: boolean,
  options: UsePortalPositionOptions = {}
): { position: PortalPosition; updatePosition: () => void } {
  const { placement = 'bottom-start', offset = 4 } = options;
  const [position, setPosition] = useState<PortalPosition>(DEFAULT_POSITION);

  const updatePosition = useCallback(() => {
    const trigger = triggerRef.current;
    if (!trigger) return;

    const rect = trigger.getBoundingClientRect();

    let top: number;
    let left: number;

    switch (placement) {
      case 'bottom-start':
        top = rect.bottom + offset;
        left = rect.left;
        break;
      case 'bottom-end':
        top = rect.bottom + offset;
        left = rect.right;
        break;
      case 'top-start':
        top = rect.top - offset;
        left = rect.left;
        break;
      case 'top-end':
        top = rect.top - offset;
        left = rect.right;
        break;
      default:
        top = rect.bottom + offset;
        left = rect.left;
    }

    setPosition({
      top,
      left,
      triggerWidth: rect.width,
      triggerHeight: rect.height,
    });
  }, [triggerRef, placement, offset]);

  // Update position when open state changes or on mount
  useEffect(() => {
    if (isOpen) {
      updatePosition();
    }
  }, [isOpen, updatePosition]);

  // Update position on scroll/resize while open
  useEffect(() => {
    if (!isOpen) return;

    const handleUpdate = () => {
      updatePosition();
    };

    // Debounced scroll handler for performance
    let rafId: number | null = null;
    const debouncedUpdate = () => {
      if (rafId) return;
      rafId = requestAnimationFrame(() => {
        handleUpdate();
        rafId = null;
      });
    };

    window.addEventListener('resize', debouncedUpdate, { passive: true });
    window.addEventListener('scroll', debouncedUpdate, { passive: true, capture: true });

    return () => {
      window.removeEventListener('resize', debouncedUpdate);
      window.removeEventListener('scroll', debouncedUpdate, { capture: true });
      if (rafId) {
        cancelAnimationFrame(rafId);
      }
    };
  }, [isOpen, updatePosition]);

  return { position, updatePosition };
}
