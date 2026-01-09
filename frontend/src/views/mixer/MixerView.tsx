/**
 * MixerView - Focused faders, meters, track control
 * Maximum real estate for level control
 */

import type { ReactElement } from 'react';
import { ViewHeader } from '../../components';

export function MixerView(): ReactElement {
  return (
    <div className="h-full bg-bg-app text-text-primary p-3 flex flex-col">
      <ViewHeader currentView="mixer" />
      <div className="flex-1 flex flex-col items-center justify-center">
        <h1 className="text-2xl font-bold mb-4">Mixer View</h1>
        <p className="text-text-secondary">Dedicated mixer coming soon</p>
      </div>
    </div>
  );
}
