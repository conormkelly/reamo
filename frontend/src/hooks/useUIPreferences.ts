/**
 * UI Preferences Hook
 * Manages user preferences for UI layout stored in localStorage
 */

import { useState, useEffect, useCallback } from 'react';

const UI_PREFS_KEY = 'reamo_ui_preferences';

export interface UIPreferences {
  showTabBar: boolean;
  showPersistentTransport: boolean;
  transportPosition: 'left' | 'right';
  notesFontSize: number;
}

const DEFAULT_PREFS: UIPreferences = {
  showTabBar: true,
  showPersistentTransport: true,
  transportPosition: 'left',
  notesFontSize: 16,
};

function loadPreferences(): UIPreferences {
  try {
    const stored = localStorage.getItem(UI_PREFS_KEY);
    if (stored) {
      return { ...DEFAULT_PREFS, ...JSON.parse(stored) };
    }
  } catch (e) {
    console.warn('Failed to load UI preferences:', e);
  }
  return DEFAULT_PREFS;
}

function savePreferences(prefs: UIPreferences): void {
  try {
    localStorage.setItem(UI_PREFS_KEY, JSON.stringify(prefs));
  } catch (e) {
    console.warn('Failed to save UI preferences:', e);
  }
}

export function useUIPreferences() {
  const [prefs, setPrefs] = useState<UIPreferences>(loadPreferences);

  // Save to localStorage whenever prefs change
  useEffect(() => {
    savePreferences(prefs);
  }, [prefs]);

  const setShowTabBar = useCallback((show: boolean) => {
    setPrefs((p) => ({ ...p, showTabBar: show }));
  }, []);

  const setShowPersistentTransport = useCallback((show: boolean) => {
    setPrefs((p) => ({ ...p, showPersistentTransport: show }));
  }, []);

  const setTransportPosition = useCallback((position: 'left' | 'right') => {
    setPrefs((p) => ({ ...p, transportPosition: position }));
  }, []);

  const toggleTabBar = useCallback(() => {
    setPrefs((p) => ({ ...p, showTabBar: !p.showTabBar }));
  }, []);

  const togglePersistentTransport = useCallback(() => {
    setPrefs((p) => ({ ...p, showPersistentTransport: !p.showPersistentTransport }));
  }, []);

  const toggleTransportPosition = useCallback(() => {
    setPrefs((p) => ({ ...p, transportPosition: p.transportPosition === 'left' ? 'right' : 'left' }));
  }, []);

  const setNotesFontSize = useCallback((size: number) => {
    setPrefs((p) => ({ ...p, notesFontSize: Math.max(8, Math.min(48, size)) }));
  }, []);

  const adjustNotesFontSize = useCallback((delta: number) => {
    setPrefs((p) => ({ ...p, notesFontSize: Math.max(8, Math.min(48, p.notesFontSize + delta)) }));
  }, []);

  return {
    ...prefs,
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
