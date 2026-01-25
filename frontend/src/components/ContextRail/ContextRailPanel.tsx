/**
 * ContextRailPanel - Overlay panel for expanded context rail content
 *
 * Features:
 * - Slides in from right edge when expanded
 * - Click outside to dismiss
 * - Contains active tab's content
 * - Animated entrance/exit with reduced-motion support
 */

import { type ReactNode, useEffect, useRef } from 'react';
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
  /** Additional CSS classes */
  className?: string;
}

export function ContextRailPanel({
  isOpen,
  onClose,
  title,
  children,
  className = '',
}: ContextRailPanelProps) {
  const panelRef = useRef<HTMLDivElement>(null);

  // Handle click outside to close
  useEffect(() => {
    if (!isOpen) return;

    const handleClickOutside = (event: MouseEvent | TouchEvent) => {
      if (panelRef.current && !panelRef.current.contains(event.target as Node)) {
        onClose();
      }
    };

    // Small delay to prevent immediate close on the click that opened it
    const timeoutId = setTimeout(() => {
      document.addEventListener('mousedown', handleClickOutside);
      document.addEventListener('touchstart', handleClickOutside);
    }, 100);

    return () => {
      clearTimeout(timeoutId);
      document.removeEventListener('mousedown', handleClickOutside);
      document.removeEventListener('touchstart', handleClickOutside);
    };
  }, [isOpen, onClose]);

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

  return (
    <div
      ref={panelRef}
      className={`
        absolute top-0 bottom-0 right-full
        bg-bg-deep border-l border-border-subtle
        flex flex-col overflow-hidden
        animate-slide-in-right
        safe-area-top safe-area-bottom
        z-dropdown
        ${className}
      `}
      style={{ width: CONTEXT_PANEL_WIDTH }}
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
    </div>
  );
}
