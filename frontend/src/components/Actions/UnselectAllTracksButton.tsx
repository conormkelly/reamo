/**
 * UnselectAllTracksButton - Deselect all tracks
 * Only visible when tracks are selected.
 */

import type { ReactElement } from 'react';
import { XCircle } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTracks } from '../../hooks';
import { track as trackCmd } from '../../core/WebSocketCommands';

export function UnselectAllTracksButton(): ReactElement | null {
  const { sendCommand } = useReaper();
  const { selectedTracks } = useTracks();

  // Only show when tracks are selected
  if (selectedTracks.length === 0) return null;

  return (
    <button
      onClick={() => sendCommand(trackCmd.unselectAll())}
      className="p-2 rounded transition-colors bg-bg-elevated text-text-tertiary hover:bg-bg-hover"
      title="Deselect all tracks"
    >
      <XCircle size={18} />
    </button>
  );
}
