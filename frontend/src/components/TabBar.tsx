/**
 * TabBar Component
 * Bottom navigation for switching between views
 * Horizontally scrollable with gradient fade indicators
 */

import { type ReactElement, useState, useRef, useEffect, useCallback } from 'react';
import { type ViewId, viewMeta } from '../viewRegistry';

export interface TabBarProps {
  currentView: ViewId;
  onViewChange: (view: ViewId) => void;
  className?: string;
}

const VIEW_ORDER: ViewId[] = ['timeline', 'mixer', 'clock', 'cues', 'actions', 'notes', 'instruments'];

export function TabBar({ currentView, onViewChange, className = '' }: TabBarProps): ReactElement {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [showLeftFade, setShowLeftFade] = useState(false);
  const [showRightFade, setShowRightFade] = useState(false);

  const updateFades = useCallback(() => {
    const el = scrollRef.current;
    if (!el) return;

    const { scrollLeft, scrollWidth, clientWidth } = el;
    setShowLeftFade(scrollLeft > 4);
    setShowRightFade(scrollLeft < scrollWidth - clientWidth - 4);
  }, []);

  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;

    // Initial check
    updateFades();

    // Listen for scroll and resize
    el.addEventListener('scroll', updateFades, { passive: true });
    window.addEventListener('resize', updateFades);

    return () => {
      el.removeEventListener('scroll', updateFades);
      window.removeEventListener('resize', updateFades);
    };
  }, [updateFades]);

  return (
    <nav className={`relative bg-bg-deep border-t border-border-muted ${className}`}>
      {/* Left fade indicator */}
      {showLeftFade && (
        <div className="absolute left-0 top-0 bottom-0 w-6 bg-gradient-to-r from-bg-deep to-transparent pointer-events-none z-10" />
      )}

      {/* Scrollable tab container */}
      <div
        ref={scrollRef}
        className="flex overflow-x-auto scrollbar-hide"
      >
        {VIEW_ORDER.map((viewId) => {
          const meta = viewMeta[viewId];
          const isActive = currentView === viewId;

          return (
            <button
              key={viewId}
              onClick={() => onViewChange(viewId)}
              className={`
                flex-shrink-0 min-w-[56px] px-3 flex items-center justify-center py-2 md:py-3 text-sm md:text-base font-medium transition-colors
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
      </div>

      {/* Right fade indicator */}
      {showRightFade && (
        <div className="absolute right-0 top-0 bottom-0 w-6 bg-gradient-to-l from-bg-deep to-transparent pointer-events-none z-10" />
      )}
    </nav>
  );
}
