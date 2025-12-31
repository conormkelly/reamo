/**
 * ActionsView - User-configurable quick action buttons
 * Grid of large touch targets for custom REAPER actions
 */

import type { ReactElement } from 'react';

export function ActionsView(): ReactElement {
  return (
    <div className="min-h-screen bg-gray-950 text-white p-4 flex flex-col items-center justify-center">
      <h1 className="text-2xl font-bold mb-4">Actions View</h1>
      <p className="text-gray-400">Quick actions coming soon</p>
    </div>
  );
}
