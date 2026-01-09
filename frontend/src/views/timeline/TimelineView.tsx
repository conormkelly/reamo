/**
 * TimelineView - Visual arrangement with regions, markers, playhead
 * Shows your song structure at a glance
 */

import type { ReactElement } from 'react';

export function TimelineView(): ReactElement {
  return (
    <div className="min-h-screen bg-bg-app text-text-primary p-4 flex flex-col items-center justify-center">
      <h1 className="text-2xl font-bold mb-4">Timeline View</h1>
      <p className="text-text-secondary">Visual arrangement coming soon</p>
    </div>
  );
}
