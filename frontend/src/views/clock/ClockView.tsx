/**
 * ClockView - Big transport, BPM, bar.beat
 * Highly configurable: show/hide elements, reorder, adjust sizes
 * Uses CSS clamp() and container-relative sizing for responsive layout
 */

import { useState, useEffect, useCallback, type ReactElement } from 'react';
import { Pencil } from 'lucide-react';
import { useReaperStore, ELEMENT_SCALE_MAP, type ClockElement } from '../../store';
import { ViewHeader } from '../../components';
import {
  BarBeatDisplay,
  TimeDisplay,
  BpmTimeSigDisplay,
  TransportControls,
  RecordingIndicator,
  ClockElementWrapper,
} from './components';

// Element labels for edit mode
const ELEMENT_LABELS: Record<ClockElement, string> = {
  barBeatTicks: 'Bar.Beat.Ticks',
  timeDisplay: 'Time (Seconds)',
  bpmTimeSig: 'BPM / Time Sig',
  transport: 'Transport',
  recordingIndicator: 'Recording Indicator',
};

export function ClockView(): ReactElement {
  // Clock config from store
  const clockConfig = useReaperStore((s) => s.clockConfig);
  const clockEditMode = useReaperStore((s) => s.clockEditMode);
  const setClockEditMode = useReaperStore((s) => s.setClockEditMode);
  const setClockElementVisible = useReaperStore((s) => s.setClockElementVisible);
  const reorderClockElements = useReaperStore((s) => s.reorderClockElements);
  const setClockScale = useReaperStore((s) => s.setClockScale);
  const loadClockViewFromStorage = useReaperStore((s) => s.loadClockViewFromStorage);
  const getSortedClockElements = useReaperStore((s) => s.getSortedClockElements);

  // Load config from storage on mount
  useEffect(() => {
    loadClockViewFromStorage();
  }, [loadClockViewFromStorage]);

  // Drag state
  const [dragFromIdx, setDragFromIdx] = useState<number | null>(null);
  const [dragOverIdx, setDragOverIdx] = useState<number | null>(null);

  // Listen for touch drag events from ClockElementWrapper
  useEffect(() => {
    const handleTouchDragOver = (e: Event) => {
      const customEvent = e as CustomEvent<{ targetIndex: number }>;
      setDragOverIdx(customEvent.detail.targetIndex);
    };
    window.addEventListener('clock-drag-over', handleTouchDragOver);
    return () => window.removeEventListener('clock-drag-over', handleTouchDragOver);
  }, []);

  // Drag handlers
  const handleDragEnd = useCallback(() => {
    if (dragFromIdx !== null && dragOverIdx !== null && dragFromIdx !== dragOverIdx) {
      reorderClockElements(dragFromIdx, dragOverIdx);
    }
    setDragFromIdx(null);
    setDragOverIdx(null);
  }, [dragFromIdx, dragOverIdx, reorderClockElements]);

  // Get sorted elements
  const sortedElements = getSortedClockElements();

  // Helper to get scale for an element
  const getScale = (id: ClockElement): number => {
    const scaleKey = ELEMENT_SCALE_MAP[id];
    return scaleKey ? clockConfig[scaleKey] : 1.0;
  };

  // Render a clock element
  const renderElement = (id: ClockElement): ReactElement | null => {
    const scale = getScale(id);

    switch (id) {
      case 'barBeatTicks':
        return <BarBeatDisplay scale={scale} />;
      case 'timeDisplay':
        return <TimeDisplay scale={scale} />;
      case 'bpmTimeSig':
        return <BpmTimeSigDisplay scale={scale} />;
      case 'transport':
        return <TransportControls scale={scale} />;
      case 'recordingIndicator':
        return <RecordingIndicator />;
      default:
        return null;
    }
  };

  return (
    <div
      data-view="clock"
      className="h-full w-full bg-bg-clock text-text-primary flex flex-col select-none overflow-hidden relative"
      style={{ containerType: 'size' }}
    >
      {/* Header overlay - semi-transparent so clock content shows through */}
      <div className="absolute top-0 left-0 right-0 z-10 p-3">
        <ViewHeader currentView="clock">
          {/* Edit mode toggle */}
          <button
            onClick={() => setClockEditMode(!clockEditMode)}
            className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg transition-colors ${
              clockEditMode
                ? 'bg-primary text-text-on-primary'
                : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
            }`}
          >
            <Pencil size={16} />
            <span className="text-sm">{clockEditMode ? 'Done' : 'Edit'}</span>
          </button>
        </ViewHeader>
      </div>

      {/* Main content - centered or scrollable in edit mode */}
      <div
        className={`flex-1 flex flex-col items-center p-2 ${
          clockEditMode
            ? 'pt-16 overflow-y-auto justify-start'
            : 'justify-center'
        }`}
      >
        {/* Vertical spacing between elements */}
        <div
          className={`flex flex-col items-center w-full ${
            clockEditMode ? 'gap-4' : 'gap-0'
          }`}
          style={
            !clockEditMode
              ? {
                  // Non-edit mode: use container-relative spacing
                  gap: 'clamp(0.25rem, 1cqh, 1.5rem)',
                }
              : undefined
          }
        >
          {sortedElements.map((element, index) => (
            <ClockElementWrapper
              key={element.id}
              id={element.id}
              label={ELEMENT_LABELS[element.id]}
              visible={element.visible}
              scale={getScale(element.id)}
              scaleKey={ELEMENT_SCALE_MAP[element.id]}
              editMode={clockEditMode}
              index={index}
              isDragTarget={dragOverIdx === index && dragFromIdx !== null && dragFromIdx !== index}
              onToggleVisible={() => setClockElementVisible(element.id, !element.visible)}
              onScaleChange={(scale) => {
                const scaleKey = ELEMENT_SCALE_MAP[element.id];
                if (scaleKey) {
                  setClockScale(scaleKey, scale);
                }
              }}
              onDragStart={() => setDragFromIdx(index)}
              onDragOver={() => setDragOverIdx(index)}
              onDragEnd={handleDragEnd}
            >
              {renderElement(element.id)}
            </ClockElementWrapper>
          ))}
        </div>
      </div>
    </div>
  );
}
