/**
 * Toast state slice
 * Manages undo/redo toast notifications
 */

import type { StateCreator } from 'zustand';

export type ToastType = 'undo' | 'redo';

export interface ToastMessage {
  type: ToastType;
  message: string;
  id: number;
}

export interface ToastSlice {
  // State
  toasts: ToastMessage[];
  nextToastId: number;

  // Actions
  showUndo: (action: string) => void;
  showRedo: (action: string) => void;
  dismissToast: (id: number) => void;
}

export const createToastSlice: StateCreator<ToastSlice> = (set, get) => ({
  // Initial state
  toasts: [],
  nextToastId: 0,

  // Actions
  showUndo: (action) => {
    const id = get().nextToastId;
    set((state) => ({
      toasts: [...state.toasts, { type: 'undo', message: action, id }],
      nextToastId: state.nextToastId + 1,
    }));
  },

  showRedo: (action) => {
    const id = get().nextToastId;
    set((state) => ({
      toasts: [...state.toasts, { type: 'redo', message: action, id }],
      nextToastId: state.nextToastId + 1,
    }));
  },

  dismissToast: (id) => {
    set((state) => ({
      toasts: state.toasts.filter((t) => t.id !== id),
    }));
  },
});
