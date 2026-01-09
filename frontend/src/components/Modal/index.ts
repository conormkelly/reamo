/**
 * Modal components for consistent modal behavior across the app
 *
 * @example
 * import { Modal, ModalContent, ModalFooter } from '../components/Modal';
 *
 * <Modal isOpen={isOpen} onClose={handleClose} title="Edit Item">
 *   <ModalContent>
 *     <form>...</form>
 *   </ModalContent>
 *   <ModalFooter
 *     onCancel={handleClose}
 *     onConfirm={handleSave}
 *     confirmText="Save"
 *   />
 * </Modal>
 */

export { Modal, type ModalProps } from './Modal';
export { ModalContent, type ModalContentProps } from './ModalContent';
export { ModalFooter, type ModalFooterProps } from './ModalFooter';
