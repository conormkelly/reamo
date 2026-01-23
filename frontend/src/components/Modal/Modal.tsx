/**
 * Modal - Unified modal wrapper component
 *
 * Provides consistent behavior across all modals:
 * - Escape key to close
 * - Backdrop click to close
 * - Focus management
 * - Consistent styling
 *
 * Renders via portal to document.body to escape all stacking contexts.
 * This ensures modals always appear above all other content regardless
 * of where they are rendered in the component tree.
 *
 * @example
 * <Modal isOpen={isOpen} onClose={handleClose} title="Edit Marker">
 *   <form>...</form>
 * </Modal>
 */

import { useEffect, useRef, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';

export interface ModalProps {
  /** Whether the modal is visible */
  isOpen: boolean;
  /** Called when modal should close (Escape, backdrop click, or X button) */
  onClose: () => void;
  /** Modal title displayed in header */
  title: string;
  /** Modal content */
  children: ReactNode;
  /** Whether to show the X close button in header. Default: true */
  showCloseButton?: boolean;
  /** Whether clicking backdrop closes modal. Default: true */
  closeOnBackdrop?: boolean;
  /** Whether Escape key closes modal. Default: true */
  closeOnEscape?: boolean;
  /** Modal width preset. Default: 'md' */
  width?: 'sm' | 'md' | 'lg' | 'xl';
  /** Optional icon to show next to title */
  icon?: ReactNode;
  /** Additional className for the modal content container */
  className?: string;
}

const WIDTH_CLASSES: Record<NonNullable<ModalProps['width']>, string> = {
  sm: 'max-w-xs',
  md: 'max-w-sm',
  lg: 'max-w-md',
  xl: 'max-w-lg',
};

export function Modal({
  isOpen,
  onClose,
  title,
  children,
  showCloseButton = true,
  closeOnBackdrop = true,
  closeOnEscape = true,
  width = 'md',
  icon,
  className = '',
}: ModalProps) {
  const modalRef = useRef<HTMLDivElement>(null);

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

  // Focus management - focus modal on open
  useEffect(() => {
    if (!isOpen) return;

    // Focus the modal container for keyboard navigation
    const timer = setTimeout(() => {
      modalRef.current?.focus();
    }, 0);

    return () => clearTimeout(timer);
  }, [isOpen]);

  // Backdrop click handler
  const handleBackdropClick = (e: React.MouseEvent) => {
    if (closeOnBackdrop && e.target === e.currentTarget) {
      onClose();
    }
  };

  if (!isOpen) return null;

  // Render via portal to escape all stacking contexts
  // This ensures the modal always appears above all other content
  return createPortal(
    <div
      className="fixed inset-0 z-modal flex items-center justify-center bg-black/60 backdrop-blur-sm"
      onClick={handleBackdropClick}
      data-testid="modal-backdrop"
    >
      <div
        ref={modalRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-labelledby="modal-title"
        className={`bg-bg-deep rounded-xl shadow-2xl border border-border-subtle w-full ${WIDTH_CLASSES[width]} mx-4 overflow-hidden outline-none ${className}`}
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-4 py-3 border-b border-border-subtle">
          <h2 id="modal-title" className="text-lg font-semibold flex items-center gap-2">
            {icon}
            {title}
          </h2>
          {showCloseButton && (
            <button
              onClick={onClose}
              className="p-1.5 rounded-lg hover:bg-bg-elevated transition-colors"
              aria-label="Close modal"
            >
              <X size={18} />
            </button>
          )}
        </div>

        {/* Content */}
        {children}
      </div>
    </div>,
    document.body
  );
}

export default Modal;
