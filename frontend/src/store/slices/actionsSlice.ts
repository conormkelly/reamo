/**
 * Actions state slice
 * Caches REAPER actions for searchable discovery
 */

import type { StateCreator } from 'zustand';

/**
 * A REAPER action from the action list.
 * Used for action search/discovery when configuring toolbar buttons.
 */
export interface ReaperAction {
  /** Numeric command ID (may be dynamic for SWS/scripts) */
  commandId: number;
  /** Section ID (0=Main, 100=Main Alt, 32060=MIDI Editor, etc.) */
  sectionId: number;
  /** Human-readable action name */
  name: string;
  /** Whether this action has toggle state */
  isToggle: boolean;
  /**
   * Stable string identifier for SWS/ReaPack/scripts (e.g., "_SWS_SAVESEL").
   * null for native REAPER actions (their numeric IDs are stable).
   * IMPORTANT: Store this value for SWS/scripts, as their numeric IDs change on restart.
   */
  namedId: string | null;
}

export interface ActionsSlice {
  // State
  actionCache: ReaperAction[];
  actionCacheLoading: boolean;
  actionCacheError: string | null;

  // Actions
  setActionCache: (actions: ReaperAction[]) => void;
  setActionCacheLoading: (loading: boolean) => void;
  setActionCacheError: (error: string | null) => void;
  clearActionCache: () => void;
}

export const createActionsSlice: StateCreator<ActionsSlice> = (set) => ({
  // Initial state
  actionCache: [],
  actionCacheLoading: false,
  actionCacheError: null,

  // Actions
  setActionCache: (actions) =>
    set({ actionCache: actions, actionCacheLoading: false, actionCacheError: null }),

  setActionCacheLoading: (loading) => set({ actionCacheLoading: loading }),

  setActionCacheError: (error) =>
    set({ actionCacheError: error, actionCacheLoading: false }),

  clearActionCache: () =>
    set({ actionCache: [], actionCacheLoading: false, actionCacheError: null }),
});

/**
 * Parse the raw response from action/getActions into ReaperAction objects.
 * Response format: [[cmdId, sectionId, name, isToggle, namedId], ...]
 */
export function parseActionResponse(
  payload: unknown
): ReaperAction[] {
  if (!Array.isArray(payload)) return [];

  return payload
    .filter((item): item is [number, number, string, number, string | null] =>
      Array.isArray(item) && item.length >= 5
    )
    .map(([commandId, sectionId, name, isToggle, namedId]) => ({
      commandId,
      sectionId,
      name,
      isToggle: isToggle === 1,
      namedId: namedId ?? null,
    }));
}
