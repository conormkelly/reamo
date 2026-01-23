/**
 * Portal - Render children into document.body
 *
 * Used to escape parent stacking contexts for overlays (modals, dropdowns, tooltips).
 * Elements rendered via portal have their z-index evaluated at the document root,
 * preventing them from being trapped behind sibling elements with higher z-index.
 *
 * @example
 * <Portal>
 *   <div className="fixed inset-0 z-modal">
 *     Modal content here
 *   </div>
 * </Portal>
 */

import { type ReactNode } from 'react';
import { createPortal } from 'react-dom';

export interface PortalProps {
  children: ReactNode;
}

export function Portal({ children }: PortalProps) {
  // SSR safety check (not needed for this app, but good practice)
  if (typeof document === 'undefined') {
    return null;
  }

  return createPortal(children, document.body);
}

export default Portal;
