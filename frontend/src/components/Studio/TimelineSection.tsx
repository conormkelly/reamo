/**
 * TimelineSection - Timeline content for Studio view
 * Renders timeline, regions, items based on current mode
 * Collapse is handled by parent CollapsibleSection wrapper
 *
 * Viewport state is lifted here so both Timeline and ItemsTimeline share the same
 * visible range. Zoom/pan in navigate mode persists when switching to items mode.
 *
 * Info bar display in navigate mode:
 * - MarkerInfoBar: shows when a marker is selected (has its own X to close)
 * - NavigateItemInfoBar: shows when itemSelectionModeActive is true (has X to exit mode)
 * - Both can be visible simultaneously
 */

import { useMemo, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { EMPTY_REGIONS, EMPTY_MARKERS, EMPTY_ITEMS } from '../../store/stableRefs';
import { useViewport, useTransport } from '../../hooks';
import {
  Timeline,
  RegionInfoBar,
  RegionEditActionBar,
  MarkerInfoBar,
  TimelineModeToggle,
  NavigateItemInfoBar,
} from '../index';

/**
 * Header controls for Timeline section (TimelineModeToggle)
 * Passed as headerControls to CollapsibleSection
 */
export function TimelineHeaderControls(): ReactElement {
  return <TimelineModeToggle />;
}

export function TimelineSection(): ReactElement {
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const regions = useReaperStore((s) => s?.regions ?? EMPTY_REGIONS);
  const markers = useReaperStore((s) => s?.markers ?? EMPTY_MARKERS);
  const items = useReaperStore((s) => s?.items ?? EMPTY_ITEMS);
  const openAddRegionModal = useReaperStore((s) => s.openAddRegionModal);
  const selectedMarkerId = useReaperStore((s) => s.selectedMarkerId);
  const itemSelectionModeActive = useReaperStore((s) => s.itemSelectionModeActive);
  const { positionSeconds } = useTransport();

  // Calculate project duration from content (same logic as Timeline.tsx)
  const projectDuration = useMemo(() => {
    let end = 0;

    for (const region of regions) {
      if (region.end > end) end = region.end;
    }
    for (const marker of markers) {
      if (marker.position > end) end = marker.position;
    }
    for (const item of items) {
      const itemEnd = item.position + item.length;
      if (itemEnd > end) end = itemEnd;
    }
    // Include playhead position
    if (positionSeconds > end) end = positionSeconds;

    // Add 5% padding at the end, minimum 10 seconds
    return Math.max(end * 1.05, 10);
  }, [regions, markers, items, positionSeconds]);

  // Shared viewport state - persists across mode switches
  const viewport = useViewport({
    projectDuration,
    initialRange: { start: 0, end: Math.min(30, projectDuration) },
  });

  return (
    <>
      {/* Timeline content */}
      <Timeline height={80} viewport={viewport} />
      <RegionInfoBar
        className="mt-2"
        onAddRegion={timelineMode === 'regions' ? openAddRegionModal : undefined}
      />
      <div className="mt-2">
        <RegionEditActionBar />
      </div>

      {/* Marker/Item Info - only shown in navigate mode */}
      {/* MarkerInfoBar and NavigateItemInfoBar can be shown simultaneously */}
      {timelineMode === 'navigate' && (
        <section data-testid="navigate-info-section" className="mt-4 flex flex-col gap-2">
          {/* Marker info bar - shown when a marker is selected */}
          <MarkerInfoBar />
          {/* Item info bar - shown when in item selection mode */}
          {itemSelectionModeActive && <NavigateItemInfoBar />}
          {/* Fallback when nothing is active */}
          {selectedMarkerId === null && !itemSelectionModeActive && (
            <div
              data-testid="nothing-selected-message"
              className="px-3 py-2 text-text-muted text-sm text-center"
            >
              Tap a marker pill or item blob to select
            </div>
          )}
        </section>
      )}
    </>
  );
}
