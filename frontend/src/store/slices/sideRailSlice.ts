/**
 * Side Rail state slice
 * Manages bank navigation and actions state that views provide for the side rail
 *
 * When a view (Mixer/Timeline) is active, it populates this state with its
 * bank navigation props and info content. The SideRail component reads from this state.
 */

import type { StateCreator } from 'zustand';
import type { ReactNode } from 'react';

/** Bank navigation props - same shape as SecondaryPanel's BankNavProps */
export interface SideRailBankNavState {
  /** Display text like "7-8 / 12" */
  bankDisplay: string;
  /** Compact display (e.g., just "12") */
  compactDisplay?: string;
  /** Whether back button is enabled */
  canGoBack: boolean;
  /** Whether forward button is enabled */
  canGoForward: boolean;
}

/** Info content state for side rail actions button */
export interface SideRailInfoState {
  /** React content to show in the info sheet */
  content: ReactNode;
  /** Label for accessibility */
  label: string;
}

/** Search/filter state for side rail */
export interface SideRailSearchState {
  /** Current search value */
  value: string;
  /** Called when value changes */
  onChange: ((value: string) => void) | null;
  /** Placeholder text */
  placeholder?: string;
}

export interface SideRailSlice {
  /** Current bank navigation state from the active view */
  sideRailBankNav: SideRailBankNavState | null;

  /** Callback refs for bank navigation (set by views) */
  sideRailBankNavCallbacks: {
    onBack: (() => void) | null;
    onForward: (() => void) | null;
  };

  /** Info content from the active view (shown in side rail Info tab) */
  sideRailInfo: SideRailInfoState | null;

  /** Toolbar content from the active view (shown in side rail Toolbar tab) */
  sideRailToolbar: SideRailInfoState | null;

  /** Search/filter state from the active view */
  sideRailSearch: SideRailSearchState | null;

  /** Set bank navigation state (called by active view) */
  setSideRailBankNav: (state: SideRailBankNavState | null) => void;

  /** Set bank navigation callbacks (called by active view) */
  setSideRailBankNavCallbacks: (callbacks: {
    onBack: (() => void) | null;
    onForward: (() => void) | null;
  }) => void;

  /** Set info content (called by active view) */
  setSideRailInfo: (info: SideRailInfoState | null) => void;

  /** Set toolbar content (called by active view) */
  setSideRailToolbar: (toolbar: SideRailInfoState | null) => void;

  /** Set search state (called by active view) */
  setSideRailSearch: (search: SideRailSearchState | null) => void;

  /** Navigate bank back */
  sideRailGoBack: () => void;

  /** Navigate bank forward */
  sideRailGoForward: () => void;
}

export const createSideRailSlice: StateCreator<SideRailSlice> = (set, get) => ({
  sideRailBankNav: null,

  sideRailBankNavCallbacks: {
    onBack: null,
    onForward: null,
  },

  sideRailInfo: null,

  sideRailToolbar: null,

  sideRailSearch: null,

  setSideRailBankNav: (state) => {
    set({ sideRailBankNav: state });
  },

  setSideRailBankNavCallbacks: (callbacks) => {
    set({ sideRailBankNavCallbacks: callbacks });
  },

  setSideRailInfo: (info) => {
    set({ sideRailInfo: info });
  },

  setSideRailToolbar: (toolbar) => {
    set({ sideRailToolbar: toolbar });
  },

  setSideRailSearch: (search) => {
    set({ sideRailSearch: search });
  },

  sideRailGoBack: () => {
    const { onBack } = get().sideRailBankNavCallbacks;
    if (onBack) onBack();
  },

  sideRailGoForward: () => {
    const { onForward } = get().sideRailBankNavCallbacks;
    if (onForward) onForward();
  },
});
