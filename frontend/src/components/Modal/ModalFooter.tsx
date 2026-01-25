/**
 * ModalFooter - Consistent footer with action buttons for modals
 *
 * @example
 * <Modal title="Delete Item">
 *   <ModalContent>Are you sure?</ModalContent>
 *   <ModalFooter
 *     onCancel={handleClose}
 *     onConfirm={handleDelete}
 *     confirmText="Delete"
 *     confirmVariant="danger"
 *   />
 * </Modal>
 */

import { Loader2 } from 'lucide-react';

export interface ModalFooterProps {
  /** Called when cancel button is clicked. If omitted, cancel button is hidden. */
  onCancel?: () => void;
  /** Called when confirm button is clicked. If omitted, confirm button is hidden. */
  onConfirm?: () => void;
  /** Cancel button text. Default: "Cancel" */
  cancelText?: string;
  /** Confirm button text. Default: "Save" */
  confirmText?: string;
  /** Whether confirm button is disabled */
  confirmDisabled?: boolean;
  /** Whether to show loading spinner on confirm button */
  confirmLoading?: boolean;
  /** Confirm button color variant. Default: "primary" */
  confirmVariant?: 'primary' | 'danger' | 'success';
  /** Additional content to render before the buttons (e.g., error message) */
  leftContent?: React.ReactNode;
}

const CONFIRM_STYLES: Record<NonNullable<ModalFooterProps['confirmVariant']>, string> = {
  primary: 'bg-primary hover:bg-primary-hover text-on-primary',
  danger: 'bg-error-action hover:bg-error text-on-error',
  success: 'bg-success-action hover:bg-success text-on-success',
};

export function ModalFooter({
  onCancel,
  onConfirm,
  cancelText = 'Cancel',
  confirmText = 'Save',
  confirmDisabled = false,
  confirmLoading = false,
  confirmVariant = 'primary',
  leftContent,
}: ModalFooterProps) {
  const hasButtons = onCancel || onConfirm;

  if (!hasButtons && !leftContent) return null;

  return (
    <div className="flex items-center justify-between gap-3 px-modal-footer-x py-modal-footer-y border-t border-border-subtle">
      {/* Left side content (e.g., error messages, additional actions) */}
      <div className="flex-1 min-w-0">
        {leftContent}
      </div>

      {/* Action buttons */}
      {hasButtons && (
        <div className="flex items-center gap-2 flex-shrink-0">
          {onCancel && (
            <button
              type="button"
              onClick={onCancel}
              className="px-4 py-2 text-sm font-medium rounded-lg bg-bg-elevated hover:bg-bg-hover text-text-secondary transition-colors"
            >
              {cancelText}
            </button>
          )}
          {onConfirm && (
            <button
              type="button"
              onClick={onConfirm}
              disabled={confirmDisabled || confirmLoading}
              className={`px-4 py-2 text-sm font-medium rounded-lg transition-colors disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2 ${CONFIRM_STYLES[confirmVariant]}`}
            >
              {confirmLoading && <Loader2 size={14} className="animate-spin" />}
              {confirmText}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

export default ModalFooter;
