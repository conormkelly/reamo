/**
 * Project Notes state slice
 * Manages project notes editing with external change detection
 */

import type { StateCreator } from 'zustand';

export interface NotesSlice {
  // State from server
  serverNotes: string | null; // Last value from server (null = never fetched)
  serverHash: string | null; // Hash of server notes for change detection

  // Local editing state
  localNotes: string; // Current editor content
  hasExternalChange: boolean; // True when server hash differs from last known

  // Loading states
  isNotesLoading: boolean;
  isNotesSaving: boolean;
  notesError: string | null;

  // Actions
  setServerNotes: (notes: string, hash: string) => void;
  setLocalNotes: (notes: string) => void;
  setExternalChange: (hasChange: boolean) => void;
  setNotesLoading: (loading: boolean) => void;
  setNotesSaving: (saving: boolean) => void;
  setNotesError: (error: string | null) => void;
  discardLocalNotes: () => void;
  handleExternalChange: (newHash: string) => void;
}

// Derived state helpers (call these with slice state)
export const getNotesIsDirty = (slice: Pick<NotesSlice, 'localNotes' | 'serverNotes'>): boolean =>
  slice.localNotes !== (slice.serverNotes ?? '');

export const getNotesIsOverLimit = (slice: Pick<NotesSlice, 'localNotes'>, limit = 5000): boolean =>
  slice.localNotes.length > limit;

export const getNotesCanSave = (
  slice: Pick<NotesSlice, 'localNotes' | 'serverNotes' | 'hasExternalChange'>,
  limit = 5000
): boolean =>
  getNotesIsDirty(slice) && !getNotesIsOverLimit(slice, limit) && !slice.hasExternalChange;

export const createNotesSlice: StateCreator<NotesSlice> = (set, get) => ({
  // Initial state
  serverNotes: null,
  serverHash: null,
  localNotes: '',
  hasExternalChange: false,
  isNotesLoading: false,
  isNotesSaving: false,
  notesError: null,

  // Actions
  setServerNotes: (notes, hash) =>
    set({
      serverNotes: notes,
      serverHash: hash,
      localNotes: notes,
      hasExternalChange: false,
      notesError: null,
    }),

  setLocalNotes: (notes) => set({ localNotes: notes }),

  setExternalChange: (hasChange) => set({ hasExternalChange: hasChange }),

  setNotesLoading: (loading) => set({ isNotesLoading: loading }),

  setNotesSaving: (saving) => set({ isNotesSaving: saving }),

  setNotesError: (error) => set({ notesError: error }),

  discardLocalNotes: () => {
    const { serverNotes } = get();
    set({
      localNotes: serverNotes ?? '',
      hasExternalChange: false,
    });
  },

  handleExternalChange: (newHash) => {
    const { serverHash } = get();
    if (serverHash !== null && serverHash !== newHash) {
      set({ hasExternalChange: true });
    }
  },
});
