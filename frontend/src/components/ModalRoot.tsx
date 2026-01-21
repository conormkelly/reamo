/**
 * ModalRoot Component
 * Renders modals based on centralized modal state from the store.
 * Decouples modal rendering from Timeline components.
 */

import { useCallback, type ReactElement } from 'react';
import { useReaperStore } from '../store';
import { useReaper } from './ReaperProvider';
import { useTimeSignature, useBarOffset } from '../hooks';
import { marker as markerCmd, action } from '../core/WebSocketCommands';

// Import modals
import { MarkerEditModal } from './Timeline/MarkerEditModal';
import { DeleteRegionModal } from './Timeline/DeleteRegionModal';
import { AddRegionModal } from './Timeline/AddRegionModal';
import { MakeSelectionModal } from './Timeline/MakeSelectionModal';
import { TimelineSettingsSheet } from './Modal';

export function ModalRoot(): ReactElement | null {
  const { sendCommand } = useReaper();
  const modal = useReaperStore((s) => s.modal);
  const closeModal = useReaperStore((s) => s.closeModal);
  const bpm = useReaperStore((s) => s.bpm);
  const barOffset = useBarOffset();
  const { beatsPerBar, denominator } = useTimeSignature();

  // Marker modal handlers
  const handleMarkerMove = useCallback(
    (markerId: number, newPositionSeconds: number) => {
      sendCommand(markerCmd.update(markerId, { position: newPositionSeconds }));
    },
    [sendCommand]
  );

  const handleMarkerDelete = useCallback(
    (markerId: number) => {
      sendCommand(markerCmd.delete(markerId));
    },
    [sendCommand]
  );

  const handleReorderAllMarkers = useCallback(() => {
    sendCommand(action.execute(40898)); // Renumber all markers in timeline order
  }, [sendCommand]);

  // Render modal based on state
  switch (modal.type) {
    case 'markerEdit':
      return (
        <MarkerEditModal
          marker={modal.marker}
          bpm={bpm || 120}
          barOffset={barOffset}
          beatsPerBar={beatsPerBar}
          denominator={denominator}
          onClose={closeModal}
          onMove={handleMarkerMove}
          onDelete={handleMarkerDelete}
          onReorderAll={handleReorderAllMarkers}
        />
      );

    case 'deleteRegion':
      return (
        <DeleteRegionModal
          isOpen
          onClose={closeModal}
          region={modal.region}
          regionId={modal.regionId}
        />
      );

    case 'addRegion':
      return <AddRegionModal isOpen onClose={closeModal} />;

    case 'makeSelection':
      return <MakeSelectionModal isOpen onClose={closeModal} />;

    case 'timelineSettings':
      return <TimelineSettingsSheet isOpen onClose={closeModal} />;

    case 'none':
    default:
      return null;
  }
}
