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

export interface ProjectSectionProps {
  /** Callback when undo is triggered (for toast notification) */
  onUndo?: (action: string) => void;
  /** Callback when redo is triggered (for toast notification) */
  onRedo?: (action: string) => void;
}

export function ProjectSection({ onUndo, onRedo }: ProjectSectionProps): ReactElement {
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
          <UndoButton onUndo={onUndo} />
          <RedoButton onRedo={onRedo} />
          <SaveButton />
        </div>
      </div>
    </>
  );
}
