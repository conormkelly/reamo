/**
 * TimelineSection - Timeline content for Studio view
 * Renders timeline, regions, items based on current mode
 * Collapse is handled by parent CollapsibleSection wrapper
 */

import { useState, useMemo, type ReactElement } from 'react';
import { RectangleHorizontal } from 'lucide-react';
import { useReaperStore } from '../../store';
import {
  Timeline,
  ItemsTimeline,
  RegionInfoBar,
  RegionEditActionBar,
  MarkerInfoBar,
  PrevMarkerButton,
  NextMarkerButton,
  AddMarkerButton,
  TimelineModeToggle,
  AddRegionModal,
  MakeSelectionModal,
} from '../index';

/**
 * Header controls for Timeline section (TimelineModeToggle)
 * Passed as headerControls to CollapsibleSection
 */
export function TimelineHeaderControls(): ReactElement {
  return <TimelineModeToggle />;
}

export function TimelineSection(): ReactElement {
  const [showAddRegionModal, setShowAddRegionModal] = useState(false);
  const [showMakeSelectionModal, setShowMakeSelectionModal] = useState(false);
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const regions = useReaperStore((s) => s.regions);
  const timeSelection = useReaperStore((s) => s.timeSelection);

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
            onAddRegion={timelineMode === 'regions' ? () => setShowAddRegionModal(true) : undefined}
          />
          <div className="mt-2">
            <RegionEditActionBar />
          </div>
        </>
      )}

      {/* Marker Info & Navigation - only shown in navigate mode */}
      {timelineMode === 'navigate' && (
        <section className="mt-6 flex flex-col sm:flex-row sm:items-center gap-3">
          {/* Marker Info Bar - shows current marker with editing */}
          <MarkerInfoBar className="flex-1" />

          {/* Navigation buttons */}
          <div className="flex items-center gap-2 flex-shrink-0">
            <button
              onClick={() => setShowMakeSelectionModal(true)}
              title="Set time selection"
              className="px-3 py-2 bg-bg-elevated text-text-primary hover:bg-bg-hover active:bg-bg-disabled rounded font-medium transition-colors flex items-center"
            >
              <RectangleHorizontal size={16} className="mr-1" />
              <span>Selection</span>
            </button>
            <PrevMarkerButton />
            <NextMarkerButton />
            <AddMarkerButton />
          </div>
        </section>
      )}

      {/* Add Region Modal */}
      <AddRegionModal
        isOpen={showAddRegionModal}
        onClose={() => setShowAddRegionModal(false)}
      />

      {/* Make Selection Modal */}
      <MakeSelectionModal
        isOpen={showMakeSelectionModal}
        onClose={() => setShowMakeSelectionModal(false)}
      />
    </>
  );
}
