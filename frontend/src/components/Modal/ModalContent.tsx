/**
 * ModalContent - Consistent content area padding for modals
 *
 * Inside Modal it's the part that scrolls when the modal meets the visible
 * viewport's height, so a ModalFooter after it stays in view.
 *
 * @example
 * <Modal title="Edit">
 *   <ModalContent>
 *     <form>...</form>
 *   </ModalContent>
 *   <ModalFooter ... />
 * </Modal>
 */

import type { ReactNode } from 'react';

export interface ModalContentProps {
  children: ReactNode;
  /** Additional className for the content container */
  className?: string;
  /** Whether to add space-y-4 for automatic spacing. Default: true */
  spaced?: boolean;
}

export function ModalContent({
  children,
  className = '',
  spaced = true,
}: ModalContentProps) {
  return (
    <div className={`p-modal min-h-0 flex-1 overflow-y-auto ${spaced ? 'space-y-4' : ''} ${className}`}>
      {children}
    </div>
  );
}

export default ModalContent;
