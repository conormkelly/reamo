/**
 * TabBar Component
 * Bottom navigation for switching between views
 */

import type { ReactElement } from 'react';
import { type ViewId, viewMeta } from '../viewRegistry';

export interface TabBarProps {
  currentView: ViewId;
  onViewChange: (view: ViewId) => void;
  className?: string;
}

const VIEW_ORDER: ViewId[] = ['studio', 'mixer', 'clock', 'cues', 'actions', 'notes'];

export function TabBar({ currentView, onViewChange, className = '' }: TabBarProps): ReactElement {
  return (
    <nav className={`flex bg-gray-900 border-t border-gray-800 ${className}`}>
      {VIEW_ORDER.map((viewId) => {
        const meta = viewMeta[viewId];
        const isActive = currentView === viewId;

        return (
          <button
            key={viewId}
            onClick={() => onViewChange(viewId)}
            className={`
              flex-1 flex items-center justify-center py-2 md:py-3 text-sm md:text-base font-medium transition-colors
              ${isActive
                ? 'text-white bg-gray-800 border-t-2 border-blue-500'
                : 'text-gray-400 hover:text-gray-200 hover:bg-gray-800/50'
              }
            `}
          >
            {meta.shortLabel || meta.label}
          </button>
        );
      })}
    </nav>
  );
}
