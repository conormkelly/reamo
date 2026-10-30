/**
 * useBackdropDismiss - Close a dialog when its backdrop is tapped
 *
 * A tap closes the dialog only if it both starts and ends on the backdrop.
 * Checking where the click ends isn't enough: on iOS, a tap on a field inside
 * the dialog while the keyboard is up closes the keyboard, which shifts the
 * page before the click is delivered, so the click can land on the backdrop.
 * A drag that starts inside the dialog and is released outside it is ignored
 * the same way, as is a press the browser cancels (it became a scroll).
 *
 * Spread the result onto the backdrop element:
 *   <div className="fixed inset-0 ..." {...useBackdropDismiss(onClose)}>
 */

import { useRef, type MouseEvent, type PointerEvent } from 'react';

export function useBackdropDismiss(onClose: () => void, enabled = true) {
  const pressStartedOnBackdrop = useRef(false);

  return {
    onPointerDown: (e: PointerEvent) => {
      pressStartedOnBackdrop.current = e.target === e.currentTarget;
    },
    onPointerCancel: () => {
      pressStartedOnBackdrop.current = false;
    },
    onClick: (e: MouseEvent) => {
      const dismiss = pressStartedOnBackdrop.current && e.target === e.currentTarget;
      pressStartedOnBackdrop.current = false;
      if (dismiss && enabled) onClose();
    },
  };
}
