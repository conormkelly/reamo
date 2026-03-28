/**
 * ContextRailPanel - Overlay panel for expanded context rail content
 *
 * Features:
 * - Portaled to document.body to escape stacking contexts (fixes z-index issues)
 * - Positioned to the left of the anchor rail
 * - Click outside to dismiss
 * - Contains active tab's content
 * - Animated entrance/exit with reduced-motion support
 */

import { type ReactNode, type RefObject, useEffect, useRef, useState, useLayoutEffect } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';
import { CONTEXT_PANEL_WIDTH } from '../../constants/layout';

export interface ContextRailPanelProps {
  /** Whether the panel is visible */
  isOpen: boolean;
  /** Called when panel should close */
  onClose: () => void;
  /** Panel title */
  title: string;
  /** Panel content */
  children: ReactNode;
  /** Reference to the anchor element (ContextRail) for positioning */
  anchorRef: RefObject<HTMLElement | null>;
  /** Additional CSS classes */
  className?: string;
}

export function ContextRailPanel({
  isOpen,
  onClose,
  title,
  children,
  anchorRef,
  className = '',
}: ContextRailPanelProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState({ left: 0 });

  // Calculate position based on anchor element
  useLayoutEffect(() => {
    if (!isOpen || !anchorRef.current) return;

    const updatePosition = () => {
      const anchorRect = anchorRef.current?.getBoundingClientRect();
      if (anchorRect) {
        // Panel appears to the LEFT of the anchor rail
        setPosition({ left: anchorRect.left - CONTEXT_PANEL_WIDTH });
      }
    };

    updatePosition();

    // Update on resize/orientation change
    window.addEventListener('resize', updatePosition);
    return () => window.removeEventListener('resize', updatePosition);
  }, [isOpen, anchorRef]);

  // Panel stays open when interacting with main content (e.g. tapping mixer strips).
  // Close only via X button, Escape key, or chevron toggle in ContextRail.

  // Handle Escape key
  useEffect(() => {
    if (!isOpen) return;

    const handleEscape = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        onClose();
      }
    };

    document.addEventListener('keydown', handleEscape);
    return () => document.removeEventListener('keydown', handleEscape);
  }, [isOpen, onClose]);

  if (!isOpen) return null;

  // Portal to document.body to escape stacking contexts
  return createPortal(
    <div
      ref={panelRef}
      className={`
        fixed top-0 bottom-0
        bg-bg-deep border-r border-border-subtle
        flex flex-col overflow-hidden
        animate-slide-in-right
        safe-area-top safe-area-bottom
        z-modal
        ${className}
      `}
      style={{ left: position.left, width: CONTEXT_PANEL_WIDTH }}
      role="dialog"
      aria-label={title}
    >
      {/* Header */}
      <div className="shrink-0 h-11 px-3 flex items-center justify-between border-b border-border-subtle">
        <h2 className="text-sm font-medium text-text-primary truncate">{title}</h2>
        <button
          onClick={onClose}
          className="w-8 h-8 flex items-center justify-center rounded-lg text-text-muted hover:text-text-primary hover:bg-bg-hover transition-colors"
          aria-label="Close panel"
        >
          <X size={18} />
        </button>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto overscroll-contain p-3">
        {children}
      </div>
    </div>,
    document.body
  );
}
