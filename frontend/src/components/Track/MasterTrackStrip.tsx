/**
 * MasterTrackStrip - Master track strip with meter
 * Always visible, not virtualized. Renders index 0.
 */

import type { ReactElement } from 'react';
import { LevelMeter } from './LevelMeter';
import { TrackStrip } from './TrackStrip';

export function MasterTrackStrip(): ReactElement {
  return (
    <div className="flex gap-1 flex-shrink-0">
      <LevelMeter trackIndex={0} height={200} />
      <TrackStrip trackIndex={0} />
    </div>
  );
}
