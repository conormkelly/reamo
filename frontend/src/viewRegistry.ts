/**
 * View Registry
 * Maps view IDs to their components for state-based routing
 */

import { StudioView } from './views/studio';
import { MixerView } from './views/mixer';
import { ClockView } from './views/clock';
import { CuesView } from './views/cues';
import { ActionsView } from './views/actions';
import { NotesView } from './views/notes';

export const views = {
  studio: StudioView,
  mixer: MixerView,
  clock: ClockView,
  cues: CuesView,
  actions: ActionsView,
  notes: NotesView,
} as const;

export type ViewId = keyof typeof views;

export const VIEW_STORAGE_KEY = 'reamo_current_view';
export const DEFAULT_VIEW: ViewId = 'studio';

// View metadata for TabBar
export const viewMeta: Record<ViewId, { label: string; shortLabel?: string }> = {
  studio: { label: 'Studio' },
  mixer: { label: 'Mixer' },
  clock: { label: 'Clock' },
  cues: { label: 'Playlist' },
  actions: { label: 'Actions' },
  notes: { label: 'Notes' },
};
