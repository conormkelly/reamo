/**
 * ToastRoot - Portal-rendered toast container
 * Renders toasts from the store via createPortal
 */

import { useEffect, type ReactElement } from 'react';
import { createPortal } from 'react-dom';
import { Undo2, Redo2 } from 'lucide-react';
import { useReaperStore, type ToastMessage } from '../../store';

interface ToastItemProps {
  toast: ToastMessage;
  onDismiss: (id: number) => void;
}

function ToastItem({ toast, onDismiss }: ToastItemProps): ReactElement {
  useEffect(() => {
    const timer = setTimeout(() => {
      onDismiss(toast.id);
    }, 2500);
    return () => clearTimeout(timer);
  }, [toast.id, onDismiss]);

  const Icon = toast.type === 'undo' ? Undo2 : Redo2;

  return (
    <div
      className="flex items-center gap-2 bg-bg-surface text-text-primary px-4 py-2 rounded-lg shadow-lg border border-border-subtle animate-slide-down"
      role="status"
      aria-live="polite"
    >
      <Icon size={16} className="text-text-secondary shrink-0" />
      <span className="text-sm">{toast.message}</span>
    </div>
  );
}

export function ToastRoot(): ReactElement | null {
  const toasts = useReaperStore((s) => s.toasts);
  const dismissToast = useReaperStore((s) => s.dismissToast);

  if (toasts.length === 0) return null;

  return createPortal(
    <div
      className="fixed left-1/2 -translate-x-1/2 z-toast flex flex-col gap-2 pointer-events-none"
      style={{ top: 'calc(1rem + env(safe-area-inset-top, 0px))' }}
    >
      {toasts.map((toast) => (
        <ToastItem key={toast.id} toast={toast} onDismiss={dismissToast} />
      ))}
    </div>,
    document.body
  );
}
