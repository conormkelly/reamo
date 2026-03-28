/**
 * View Registry
 * Maps view IDs to their components for state-based routing
 */

import { MixerView } from './views/mixer';
import { TimelineView } from './views/timeline';
import { ClockView } from './views/clock';
import { PlaylistView } from './views/playlist';
import { ActionsView } from './views/actions';
import { NotesView } from './views/notes';
import { InstrumentsView } from './views/instruments';
import { TunerView } from './views/tuner';

export const views = {
  mixer: MixerView,
  timeline: TimelineView,
  clock: ClockView,
  playlist: PlaylistView,
  actions: ActionsView,
  notes: NotesView, // Hidden from tab bar but still valid view
  instruments: InstrumentsView,
  tuner: TunerView,
} as const;

export type ViewId = keyof typeof views;

export const VIEW_STORAGE_KEY = 'reamo_current_view';
export const DEFAULT_VIEW: ViewId = 'timeline';

/** Canonical tab/rail order — single source of truth for TabBar, SideRail, SettingsMenu */
export const VIEW_ORDER: ViewId[] = ['timeline', 'mixer', 'clock', 'tuner', 'actions', 'notes', 'instruments'];

// View metadata for TabBar (notes excluded from VIEW_ORDER in TabBar.tsx)
export const viewMeta: Record<ViewId, { label: string; shortLabel?: string }> = {
  mixer: { label: 'Mixer' },
  timeline: { label: 'Timeline' },
  clock: { label: 'Clock' },
  playlist: { label: 'Playlist' },
  actions: { label: 'Actions' },
  notes: { label: 'Notes' }, // Not shown in tab bar but needs metadata
  instruments: { label: 'Instruments', shortLabel: 'Inst' },
  tuner: { label: 'Tuner' },
};
