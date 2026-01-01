/**
 * ProjectSection Component
 * Combines Time Display + TransportBar + Undo/Redo/Save into one collapsible section
 */

import type { ReactElement } from 'react';
import {
  TimeDisplay,
  TransportBar,
  UndoButton,
  RedoButton,
  SaveButton,
} from '../';
import { useToast } from '../Toast';

export function ProjectSection(): ReactElement {
  const { showUndo, showRedo } = useToast();

  return (
    <>
      {/* Time Display - centered above transport */}
      <div className="flex justify-center mb-4">
        <TimeDisplay format="both" />
      </div>

      {/* Transport Controls */}
      <div className="mb-4">
        <TransportBar className="mb-3" />
        <div className="flex flex-wrap items-center justify-center gap-2">
          <UndoButton onUndo={showUndo} />
          <RedoButton onRedo={showRedo} />
          <SaveButton />
        </div>
      </div>
    </>
  );
}
