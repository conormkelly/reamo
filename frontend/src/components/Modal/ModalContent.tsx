/**
 * ModalContent - Consistent content area padding for modals
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
    <div className={`p-modal ${spaced ? 'space-y-4' : ''} ${className}`}>
      {children}
    </div>
  );
}

export default ModalContent;
