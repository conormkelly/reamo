/**
 * Toast component for undo/redo feedback
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react';
import { Undo2, Redo2 } from 'lucide-react';

export type ToastType = 'undo' | 'redo';

export interface ToastMessage {
  type: ToastType;
  message: string;
  id: number;
}

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
      className="flex items-center gap-2 bg-gray-800 text-white px-4 py-2 rounded-lg shadow-lg border border-gray-700 animate-slide-up"
      role="status"
      aria-live="polite"
    >
      <Icon size={16} className="text-gray-400 shrink-0" />
      <span className="text-sm">{toast.message}</span>
    </div>
  );
}

interface ToastContainerProps {
  toasts: ToastMessage[];
  onDismiss: (id: number) => void;
}

export function ToastContainer({ toasts, onDismiss }: ToastContainerProps): ReactElement | null {
  if (toasts.length === 0) return null;

  return (
    <div className="fixed bottom-20 left-1/2 -translate-x-1/2 z-50 flex flex-col gap-2 pointer-events-none">
      {toasts.map((toast) => (
        <ToastItem key={toast.id} toast={toast} onDismiss={onDismiss} />
      ))}
    </div>
  );
}

/**
 * Hook for managing toast state
 */
export function useToast() {
  const [toasts, setToasts] = useState<ToastMessage[]>([]);
  const [nextId, setNextId] = useState(0);

  const showToast = useCallback((type: ToastType, message: string) => {
    const id = nextId;
    setNextId((prev) => prev + 1);
    setToasts((prev) => [...prev, { type, message, id }]);
  }, [nextId]);

  const dismissToast = useCallback((id: number) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  const showUndo = useCallback((action: string) => {
    showToast('undo', action);
  }, [showToast]);

  const showRedo = useCallback((action: string) => {
    showToast('redo', action);
  }, [showToast]);

  return {
    toasts,
    showUndo,
    showRedo,
    dismissToast,
  };
}
