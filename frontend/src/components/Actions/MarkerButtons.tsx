/**
 * Marker Navigation Buttons
 * Add, Previous, and Next marker buttons
 */

import { type ReactElement } from 'react';
import { MapPinPlus, SkipBack, SkipForward } from 'lucide-react';
import { ActionButton } from './ActionButton';

export interface AddMarkerButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Button to insert a marker at the current playback position
 * Action ID 40157: Insert marker at current position
 */
export function AddMarkerButton({
  className = '',
  size = 'md',
}: AddMarkerButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40157}
      title="Add Marker"
      className={`flex items-center ${className}`}
      size={size}
    >
      <MapPinPlus size={16} className="mr-1" />
      <span>Add Marker</span>
    </ActionButton>
  );
}

export interface PrevMarkerButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Button to go to previous marker or project start
 * Action ID 40172: Go to previous marker/project start
 */
export function PrevMarkerButton({
  className = '',
  size = 'md',
}: PrevMarkerButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40172}
      title="Previous Marker"
      className={`flex items-center ${className}`}
      size={size}
    >
      <SkipBack size={20} />
    </ActionButton>
  );
}

export interface NextMarkerButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Button to go to next marker or project end
 * Action ID 40173: Go to next marker/project end
 */
export function NextMarkerButton({
  className = '',
  size = 'md',
}: NextMarkerButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40173}
      title="Next Marker"
      className={`flex items-center ${className}`}
      size={size}
    >
      <SkipForward size={20} />
    </ActionButton>
  );
}
