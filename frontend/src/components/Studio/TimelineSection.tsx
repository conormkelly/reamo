/**
 * TimelineSection - Timeline content for Studio view
 * Renders timeline, regions, items based on current mode
 * Collapse is handled by parent CollapsibleSection wrapper
 */

import { useMemo, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import {
  Timeline,
  ItemsTimeline,
  RegionInfoBar,
  RegionEditActionBar,
  MarkerInfoBar,
  TimelineModeToggle,
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
  const regions = useReaperStore((s) => s.regions);
  const timeSelection = useReaperStore((s) => s.timeSelection);
  const openAddRegionModal = useReaperStore((s) => s.openAddRegionModal);

  // Compute timeline bounds for Items mode
  const itemsTimelineBounds = useMemo(() => {
    // Use time selection if available
    if (timeSelection && timeSelection.endSeconds > timeSelection.startSeconds) {
      return { start: timeSelection.startSeconds, end: timeSelection.endSeconds };
    }
    // Fall back to region bounds
    if (regions.length > 0) {
      const start = Math.min(...regions.map((r) => r.start));
      const end = Math.max(...regions.map((r) => r.end));
      return { start, end };
    }
    // Default to 0-60 seconds
    return { start: 0, end: 60 };
  }, [timeSelection, regions]);

  return (
    <>
      {/* Timeline content - varies by mode */}
      {timelineMode === 'items' ? (
        <ItemsTimeline
          timelineStart={itemsTimelineBounds.start}
          timelineEnd={itemsTimelineBounds.end}
          height={120}
        />
      ) : (
        <>
          <Timeline height={80} />
          <RegionInfoBar
            className="mt-2"
            onAddRegion={timelineMode === 'regions' ? openAddRegionModal : undefined}
          />
          <div className="mt-2">
            <RegionEditActionBar />
          </div>
        </>
      )}

      {/* Marker Info - only shown in navigate mode */}
      {timelineMode === 'navigate' && (
        <section className="mt-4">
          <MarkerInfoBar />
        </section>
      )}
    </>
  );
}
