/**
 * View Registry
 * Maps view IDs to their components for state-based routing
 */

import { MixerView } from './views/mixer';
import { TimelineView } from './views/timeline';
import { ClockView } from './views/clock';
import { CuesView } from './views/cues';
import { ActionsView } from './views/actions';
import { NotesView } from './views/notes';

export const views = {
  mixer: MixerView,
  timeline: TimelineView,
  clock: ClockView,
  cues: CuesView,
  actions: ActionsView,
  notes: NotesView,
} as const;

export type ViewId = keyof typeof views;

export const VIEW_STORAGE_KEY = 'reamo_current_view';
export const DEFAULT_VIEW: ViewId = 'timeline';

// View metadata for TabBar
export const viewMeta: Record<ViewId, { label: string; shortLabel?: string }> = {
  mixer: { label: 'Mixer' },
  timeline: { label: 'Timeline' },
  clock: { label: 'Clock' },
  cues: { label: 'Playlist' },
  actions: { label: 'Actions' },
  notes: { label: 'Notes' },
};
