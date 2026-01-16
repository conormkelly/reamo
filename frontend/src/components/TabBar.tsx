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

const VIEW_ORDER: ViewId[] = ['timeline', 'mixer', 'clock', 'cues', 'actions', 'instruments'];

export function TabBar({ currentView, onViewChange, className = '' }: TabBarProps): ReactElement {
  return (
    <nav className={`flex bg-bg-deep border-t border-border-muted ${className}`}>
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
                ? 'text-text-primary bg-bg-surface border-t-2 border-primary'
                : 'text-text-secondary hover:text-text-tertiary hover:bg-bg-surface/50'
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
