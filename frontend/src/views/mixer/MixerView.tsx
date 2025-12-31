/**
 * MixerView - Focused faders, meters, track control
 * Maximum real estate for level control
 */

import type { ReactElement } from 'react';

export function MixerView(): ReactElement {
  return (
    <div className="min-h-screen bg-gray-950 text-white p-4 flex flex-col items-center justify-center">
      <h1 className="text-2xl font-bold mb-4">Mixer View</h1>
      <p className="text-gray-400">Dedicated mixer coming soon</p>
    </div>
  );
}
