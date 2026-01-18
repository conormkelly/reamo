/**
 * FX Browser state slice
 * Caches the installed FX plugin list (fetched once per session)
 *
 * Used by FxBrowserModal to display available plugins for adding to tracks.
 * Plugin list is large (~1MB) so we fetch once and cache.
 */

import type { StateCreator } from 'zustand';

/** Plugin entry: [displayName, ident] */
export type FxPlugin = [string, string];

export interface FxBrowserSlice {
  // Plugin list state
  /** Cached plugin list (null = not fetched yet) */
  fxPluginList: FxPlugin[] | null;
  /** Whether we're currently fetching the plugin list */
  fxPluginListLoading: boolean;
  /** Error message if fetch failed */
  fxPluginListError: string | null;

  // Actions
  /** Set loading state before fetching */
  setFxPluginListLoading: (loading: boolean) => void;
  /** Set the plugin list after successful fetch */
  setFxPluginList: (plugins: FxPlugin[]) => void;
  /** Set error state on fetch failure */
  setFxPluginListError: (error: string | null) => void;
  /** Clear the plugin list (e.g., on disconnect) */
  clearFxPluginList: () => void;
}

export const createFxBrowserSlice: StateCreator<FxBrowserSlice, [], [], FxBrowserSlice> = (set) => ({
  // Initial state
  fxPluginList: null,
  fxPluginListLoading: false,
  fxPluginListError: null,

  // Actions
  setFxPluginListLoading: (loading) =>
    set({
      fxPluginListLoading: loading,
      // Clear error when starting new fetch
      fxPluginListError: loading ? null : undefined,
    }),

  setFxPluginList: (plugins) =>
    set({
      fxPluginList: plugins,
      fxPluginListLoading: false,
      fxPluginListError: null,
    }),

  setFxPluginListError: (error) =>
    set({
      fxPluginListError: error,
      fxPluginListLoading: false,
    }),

  clearFxPluginList: () =>
    set({
      fxPluginList: null,
      fxPluginListLoading: false,
      fxPluginListError: null,
    }),
});

// =============================================================================
// Utility functions for plugin type detection
// =============================================================================

export type PluginType = 'AU' | 'VST3' | 'VST2' | 'JS' | 'Other';

/**
 * Detect plugin type from the display name.
 * Display names have type prefixes:
 * - AU: "AU: Plugin (Vendor)" or "AUi: Plugin (Vendor)" (instrument)
 * - VST3: "VST3: Plugin (Vendor)" or "VST3i: Plugin (Vendor)"
 * - VST2: "VST: Plugin (Vendor)" or "VSTi: Plugin (Vendor)"
 * - JS: "JS: path/to/script"
 */
export function getPluginType(name: string): PluginType {
  const upper = name.toUpperCase();
  // AU plugins: "AU:" or "AUi:" prefix
  if (upper.startsWith('AU:') || upper.startsWith('AUI:')) return 'AU';
  // JS plugins: "JS:" prefix
  if (upper.startsWith('JS:')) return 'JS';
  // VST3 plugins: "VST3:" or "VST3i:" prefix
  if (upper.startsWith('VST3:') || upper.startsWith('VST3I:')) return 'VST3';
  // VST2 plugins: "VST:" or "VSTi:" prefix (but not VST3)
  if (upper.startsWith('VST:') || upper.startsWith('VSTI:')) return 'VST2';
  return 'Other';
}

/**
 * Get display badge text for plugin type
 */
export function getPluginTypeBadge(type: PluginType): string {
  switch (type) {
    case 'AU': return 'AU';
    case 'VST3': return 'VST3';
    case 'VST2': return 'VST';
    case 'JS': return 'JS';
    default: return '';
  }
}
