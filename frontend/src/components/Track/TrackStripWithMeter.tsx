/**
 * TrackStripWithMeter - Track strip with level meter
 * Used in virtualized track lists.
 */

import type { ReactElement } from 'react';
import { LevelMeter } from './LevelMeter';
import { TrackStrip } from './TrackStrip';

export interface TrackStripWithMeterProps {
  trackIndex: number;
}

export function TrackStripWithMeter({ trackIndex }: TrackStripWithMeterProps): ReactElement {
  return (
    <div className="flex gap-1 flex-shrink-0">
      <LevelMeter trackIndex={trackIndex} height={200} />
      <TrackStrip trackIndex={trackIndex} />
    </div>
  );
}
