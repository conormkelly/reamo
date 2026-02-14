/**
 * MarkerNavigationPanel - Quick navigation to markers and regions
 *
 * Slide-up panel triggered by long-press on time display.
 * Shows sorted list of markers and region start points.
 * Tap any item to seek to that position.
 */

import { useCallback, useMemo, type ReactElement } from 'react';
import { MapPin, Layers, ArrowLeftToLine, ArrowRightToLine } from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { transport, action } from '../../core/WebSocketCommands';
import { formatTime, reaperColorToHexWithFallback } from '../../utils';
import type { Marker, Region } from '../../core/types';

export interface MarkerNavigationPanelProps {
  isOpen: boolean;
  onClose: () => void;
}

interface NavigationItem {
  type: 'marker' | 'region';
  id: number;
  name: string;
  position: number;
  positionBars?: string;
  color?: number;
}

export function MarkerNavigationPanel({ isOpen, onClose }: MarkerNavigationPanelProps): ReactElement {
  const { sendCommand } = useReaper();

  // Get markers and regions from store
  const markers = useReaperStore((s) => s.markers);
  const regions = useReaperStore((s) => s.regions);

  // Combine and sort by position
  const navigationItems = useMemo((): NavigationItem[] => {
    const items: NavigationItem[] = [];

    // Add markers
    markers.forEach((marker: Marker) => {
      items.push({
        type: 'marker',
        id: marker.id,
        name: marker.name || `Marker ${marker.id}`,
        position: marker.position,
        positionBars: marker.positionBars,
        color: marker.color,
      });
    });

    // Add region start points
    regions.forEach((region: Region) => {
      items.push({
        type: 'region',
        id: region.id,
        name: region.name || `Region ${region.id}`,
        position: region.start,
        positionBars: region.startBars,
        color: region.color,
      });
    });

    // Sort by position
    return items.sort((a, b) => a.position - b.position);
  }, [markers, regions]);

  // Handle item tap - seek to position
  const handleItemClick = useCallback(
    (position: number) => {
      sendCommand(transport.seek(position));
      onClose();
    },
    [sendCommand, onClose]
  );

  // Handle action command (project start/end)
  const handleActionClick = useCallback(
    (commandId: number) => {
      sendCommand(action.execute(commandId));
      onClose();
    },
    [sendCommand, onClose]
  );

  const hasItems = navigationItems.length > 0;

  return (
    <BottomSheet isOpen={isOpen} onClose={onClose} ariaLabel="Marker navigation">
      <div className="px-sheet-x pb-sheet-bottom">
        {/* Header */}
        <div className="text-center mb-3 pt-1">
          <h2 className="text-lg font-semibold text-text-primary">Jump to...</h2>
        </div>

        {/* Pinned project navigation */}
        <div className="space-y-1 mb-3">
          <button
            onClick={() => handleActionClick(40042)}
            className="w-full flex items-center gap-3 px-3 py-3 rounded-xl bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled transition-colors text-left"
          >
            <ArrowLeftToLine size={16} className="text-accent flex-shrink-0" />
            <span className="flex-1 text-text-primary">Start of Project</span>
          </button>
          <button
            onClick={() => handleActionClick(40043)}
            className="w-full flex items-center gap-3 px-3 py-3 rounded-xl bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled transition-colors text-left"
          >
            <ArrowRightToLine size={16} className="text-accent flex-shrink-0" />
            <span className="flex-1 text-text-primary">End of Project</span>
          </button>
        </div>

        {hasItems ? (
          <div className="max-h-[min(20rem,50dvh)] overflow-y-auto -mx-4 px-4">
            <ul className="space-y-1" role="listbox" aria-label="Navigation points">
              {navigationItems.map((item) => (
                <li key={`${item.type}-${item.id}`}>
                  <button
                    onClick={() => handleItemClick(item.position)}
                    className="w-full flex items-center gap-3 px-3 py-3 rounded-xl bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled transition-colors text-left"
                    role="option"
                  >
                    {/* Color indicator */}
                    <div
                      className="w-3 h-3 rounded-full flex-shrink-0"
                      style={{
                        backgroundColor: reaperColorToHexWithFallback(
                          item.color,
                          item.type === 'marker' ? 'var(--color-marker-default)' : 'var(--color-region-default)'
                        ),
                      }}
                    />

                    {/* Type icon */}
                    <div className="text-text-muted flex-shrink-0">
                      {item.type === 'marker' ? (
                        <MapPin size={16} />
                      ) : (
                        <Layers size={16} />
                      )}
                    </div>

                    {/* Name */}
                    <span className="flex-1 text-text-primary truncate">{item.name}</span>

                    {/* Position */}
                    <span className="text-text-secondary font-mono text-sm flex-shrink-0">
                      {item.positionBars || formatTime(item.position, { precision: 1 })}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          </div>
        ) : (
          <div className="text-center py-8 text-text-muted">
            <MapPin size={32} className="mx-auto mb-2 opacity-50" />
            <p>No markers or regions in project</p>
            <p className="text-sm mt-1">Add markers in REAPER to navigate here</p>
          </div>
        )}

        {/* Summary footer */}
        {hasItems && (
          <div className="text-xs text-text-muted text-center mt-3 pt-3 border-t border-border-subtle">
            {markers.length} marker{markers.length !== 1 ? 's' : ''} &middot;{' '}
            {regions.length} region{regions.length !== 1 ? 's' : ''}
          </div>
        )}
      </div>
    </BottomSheet>
  );
}

export default MarkerNavigationPanel;
