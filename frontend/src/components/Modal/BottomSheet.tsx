/**
 * BottomSheet - Slide-up panel component
 *
 * A reusable bottom sheet that slides up from the bottom of the screen.
 * Used for quick actions, navigation lists, and other contextual panels.
 *
 * Renders via portal to document.body to escape all stacking contexts.
 * Multiple sheets stack naturally by DOM order (later sheets on top).
 *
 * @example
 * <BottomSheet isOpen={isOpen} onClose={handleClose}>
 *   <div>Panel content</div>
 * </BottomSheet>
 */

import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

export interface BottomSheetProps {
  /** Whether the bottom sheet is visible */
  isOpen: boolean;
  /** Called when bottom sheet should close (Escape, backdrop click) */
  onClose: () => void;
  /** Bottom sheet content */
  children: ReactNode;
  /** Whether clicking backdrop closes sheet. Default: true */
  closeOnBackdrop?: boolean;
  /** Whether Escape key closes sheet. Default: true */
  closeOnEscape?: boolean;
  /** Accessible label for the sheet */
  ariaLabel?: string;
}

export function BottomSheet({
  isOpen,
  onClose,
  children,
  closeOnBackdrop = true,
  closeOnEscape = true,
  ariaLabel = 'Bottom sheet',
}: BottomSheetProps) {
  const sheetRef = useRef<HTMLDivElement>(null);
  const [isAnimating, setIsAnimating] = useState(false);
  const [shouldRender, setShouldRender] = useState(false);

  // Timer refs for two-phase cleanup (see FRONTEND_DEVELOPMENT.md §4)
  const rafRef = useRef<number | null>(null);
  const closeTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Cancel helper - prevents double-clear bugs
  const cancelTimers = useCallback(() => {
    if (rafRef.current !== null) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
    if (closeTimerRef.current !== null) {
      clearTimeout(closeTimerRef.current);
      closeTimerRef.current = null;
    }
  }, []);

  // Handle open/close with animation
  useEffect(() => {
    // Cancel any pending timers before starting new ones
    cancelTimers();

    if (isOpen) {
      setShouldRender(true);
      // Small delay to ensure DOM is ready before animating
      // Use nested RAF to wait for both layout and paint
      rafRef.current = requestAnimationFrame(() => {
        rafRef.current = requestAnimationFrame(() => {
          rafRef.current = null; // Self-clear on completion
          setIsAnimating(true);
        });
      });
    } else {
      setIsAnimating(false);
      // Wait for exit animation before unmounting
      closeTimerRef.current = setTimeout(() => {
        closeTimerRef.current = null; // Self-clear on completion
        setShouldRender(false);
      }, 200); // Match transition duration
    }

    return cancelTimers;
  }, [isOpen, cancelTimers]);

  // Escape key handler
  useEffect(() => {
    if (!isOpen || !closeOnEscape) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onClose();
      }
    };

    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [isOpen, closeOnEscape, onClose]);

  // Focus management - focus sheet on open
  useEffect(() => {
    if (!isOpen) return;

    const timer = setTimeout(() => {
      sheetRef.current?.focus();
    }, 0);

    return () => clearTimeout(timer);
  }, [isOpen]);

  // Backdrop click handler
  const handleBackdropClick = (e: React.MouseEvent) => {
    if (closeOnBackdrop && e.target === e.currentTarget) {
      onClose();
    }
  };

  if (!shouldRender) return null;

  // Render via portal to escape all stacking contexts
  // Multiple sheets stack naturally by DOM order (later sheets on top)
  return createPortal(
    <div
      className={`fixed inset-0 z-modal flex items-end justify-center transition-colors duration-200 ${
        isAnimating ? 'bg-black/60' : 'bg-black/0'
      }`}
      onClick={handleBackdropClick}
      data-testid="bottom-sheet-backdrop"
    >
      <div
        ref={sheetRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label={ariaLabel}
        className={`bg-bg-deep rounded-t-2xl shadow-2xl border-t border-x border-border-subtle w-full max-w-md mx-0 outline-none transform transition-transform duration-200 ease-out safe-area-bottom ${
          isAnimating ? 'translate-y-0' : 'translate-y-full'
        }`}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Drag handle indicator */}
        <div className="flex justify-center pt-3 pb-2">
          <div className="w-10 h-1 bg-border-default rounded-full" />
        </div>

        {/* Content */}
        {children}
      </div>
    </div>,
    document.body
  );
}

export default BottomSheet;
