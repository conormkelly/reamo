/**
 * useDialogFocus - Focus handling for a dialog container
 *
 * On open, focuses the container so keyboard users land inside the dialog,
 * unless something inside it already has focus: a field with autoFocus must
 * keep it, or the on-screen keyboard that opened for it closes again and the
 * field can't be typed in.
 *
 * On close, blurs whatever inside the dialog has focus while it is still on
 * the page, so the on-screen keyboard closes the normal way instead of the
 * browser finding its focused field removed. Closing covers both the dialog
 * being told it's closed and the container leaving the page.
 *
 * Attach the returned ref to the container, which needs tabIndex={-1}:
 *   const focusRef = useDialogFocus(isOpen);
 *   <div ref={focusRef} tabIndex={-1} role="dialog">...</div>
 */

import { useCallback, useEffect, useRef, type RefCallback } from 'react';

/** Blurs the focused element if it's inside the container; returns it. */
function blurFocusWithin(container: HTMLElement | null): HTMLElement | null {
  const focused = document.activeElement;
  if (container && focused instanceof HTMLElement && container.contains(focused)) {
    focused.blur();
    return focused;
  }
  return null;
}

export function useDialogFocus(isOpen: boolean): RefCallback<HTMLElement> {
  const containerRef = useRef<HTMLElement | null>(null);
  const blurredOnDetachRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!isOpen) {
      blurFocusWithin(containerRef.current);
      return;
    }

    // After the children's own focus handling (autoFocus, effects) has run.
    const timer = setTimeout(() => {
      const container = containerRef.current;
      if (container && !container.contains(document.activeElement)) {
        container.focus();
      }
    }, 0);

    return () => clearTimeout(timer);
  }, [isOpen]);

  return useCallback((node: HTMLElement | null) => {
    containerRef.current = node;
    if (!node) return;

    // StrictMode detaches and reattaches the same node in development; give
    // focus back to what the detach took it from.
    const blurred = blurredOnDetachRef.current;
    blurredOnDetachRef.current = null;
    if (blurred && node.contains(blurred)) blurred.focus();

    // Runs while the node is still on the page, before React removes it.
    return () => {
      blurredOnDetachRef.current = blurFocusWithin(node);
      containerRef.current = null;
    };
  }, []);
}
