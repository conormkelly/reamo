/**
 * ClockView - Big transport, BPM, bar.beat
 * Highly configurable: show/hide elements, reorder, adjust sizes
 * Uses CSS clamp() and container-relative sizing for responsive layout
 */

import { useState, useRef, useEffect, useCallback, type ReactElement } from 'react';
import { Pencil, Maximize, Minimize } from 'lucide-react';
import { useReaperStore, ELEMENT_SCALE_MAP, type ClockElement } from '../../store';
import { ViewHeader, ViewLayout } from '../../components';
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

  // Fullscreen (chrome-hidden) state — stored in Zustand so App can hide SideRail
  const isFullscreen = useReaperStore((s) => s.clockFullscreen);
  const setClockFullscreen = useReaperStore((s) => s.setClockFullscreen);
  const [chromeVisible, setChromeVisible] = useState(false);
  const chromeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // In fullscreen, tapping the clock briefly reveals the header
  const handleFullscreenTap = useCallback(() => {
    if (!isFullscreen || clockEditMode) return;
    setChromeVisible(true);
    if (chromeTimer.current) clearTimeout(chromeTimer.current);
    chromeTimer.current = setTimeout(() => setChromeVisible(false), 3000);
  }, [isFullscreen, clockEditMode]);

  // Clean up timer on unmount or view change
  useEffect(() => {
    return () => {
      if (chromeTimer.current) clearTimeout(chromeTimer.current);
      // Reset fullscreen when leaving the clock view
      setClockFullscreen(false);
    };
  }, [setClockFullscreen]);

  // Exit fullscreen when entering edit mode
  useEffect(() => {
    if (clockEditMode) {
      setClockFullscreen(false);
      setChromeVisible(false);
    }
  }, [clockEditMode, setClockFullscreen]);

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
    <ViewLayout
      viewId="clock"
      scrollable={false}
      className="bg-bg-clock text-text-primary"
    >
      {/* Container for clock content with container queries */}
      <div
        className="h-full w-full relative overflow-hidden"
        style={{ containerType: 'size' }}
        onClick={isFullscreen ? handleFullscreenTap : undefined}
      >
        {/* Header overlay - hidden in fullscreen unless tapped */}
        {(!isFullscreen || chromeVisible) && (
          <div className={`absolute top-0 left-0 right-0 z-elevated p-3 transition-opacity duration-300 ${
            isFullscreen && chromeVisible ? 'bg-bg-deep/80' : ''
          }`}>
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

              {/* Fullscreen toggle */}
              {!clockEditMode && (
                <button
                  onClick={() => {
                    setClockFullscreen(!isFullscreen);
                    setChromeVisible(false);
                    if (chromeTimer.current) clearTimeout(chromeTimer.current);
                  }}
                  className="ml-2 flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-bg-elevated text-text-tertiary hover:bg-bg-hover transition-colors"
                  title={isFullscreen ? 'Exit fullscreen' : 'Fullscreen'}
                  aria-label={isFullscreen ? 'Exit fullscreen' : 'Enter fullscreen'}
                >
                  {isFullscreen ? <Minimize size={16} /> : <Maximize size={16} />}
                </button>
              )}
            </ViewHeader>
          </div>
        )}

        {/* Main content - centered or scrollable in edit mode */}
        <div
          className={`h-full flex flex-col items-center p-2 ${
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
    </ViewLayout>
  );
}
