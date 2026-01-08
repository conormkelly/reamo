/**
 * UI Preferences Hook
 * Provides access to UI preferences from Zustand store
 * Preferences are persisted to localStorage via the store slice
 */

import { useReaperStore } from '../store';

export interface UIPreferences {
  showTabBar: boolean;
  showPersistentTransport: boolean;
  transportPosition: 'left' | 'right';
  notesFontSize: number;
}

export function useUIPreferences() {
  const showTabBar = useReaperStore((s) => s.showTabBar);
  const showPersistentTransport = useReaperStore((s) => s.showPersistentTransport);
  const transportPosition = useReaperStore((s) => s.transportPosition);
  const notesFontSize = useReaperStore((s) => s.notesFontSize);
  const setShowTabBar = useReaperStore((s) => s.setShowTabBar);
  const setShowPersistentTransport = useReaperStore((s) => s.setShowPersistentTransport);
  const setTransportPosition = useReaperStore((s) => s.setTransportPosition);
  const toggleTabBar = useReaperStore((s) => s.toggleTabBar);
  const togglePersistentTransport = useReaperStore((s) => s.togglePersistentTransport);
  const toggleTransportPosition = useReaperStore((s) => s.toggleTransportPosition);
  const setNotesFontSize = useReaperStore((s) => s.setNotesFontSize);
  const adjustNotesFontSize = useReaperStore((s) => s.adjustNotesFontSize);

  return {
    showTabBar,
    showPersistentTransport,
    transportPosition,
    notesFontSize,
    setShowTabBar,
    setShowPersistentTransport,
    setTransportPosition,
    toggleTabBar,
    togglePersistentTransport,
    toggleTransportPosition,
    setNotesFontSize,
    adjustNotesFontSize,
  };
}
