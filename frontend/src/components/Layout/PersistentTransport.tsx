/**
 * PersistentTransport Component
 * Always-visible transport bar at the bottom of the screen
 * Contains transport controls + time display + BPM
 */

import type { ReactElement } from 'react';
import { useState, useRef, useCallback } from 'react';
import { SkipBack, Play, Pause, Square } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTransport } from '../../hooks/useTransport';
import { useReaperStore } from '../../store';
import { useRecordButton } from '../../hooks/useRecordButton';
import { transport } from '../../core/WebSocketCommands';
import { useTransportAnimation, useDoubleTap, useLongPress } from '../../hooks';
import { formatTime } from '../../utils';
import { QuickActionsPanel } from './QuickActionsPanel';
import { MarkerNavigationPanel } from './MarkerNavigationPanel';
import { CircularTransportButton } from '../Transport/CircularTransportButton';
import { RecordModeIcon } from '../Transport/RecordModeIcon';
import { recordModeTitle } from '../../hooks/useRecordButton';

export interface PersistentTransportProps {
  className?: string;
  /** Position of transport buttons - 'left' (default) or 'right' */
  position?: 'left' | 'right';
}

export function PersistentTransport({ className = '', position = 'left' }: PersistentTransportProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isPlaying, isPaused, isStopped, isRecording, play, pause, stop } = useTransport();
  const bpm = useReaperStore((state) => state.bpm);
  const timeSignatureNumerator = useReaperStore((state) => state.timeSignatureNumerator);
  const timeSignatureDenominator = useReaperStore((state) => state.timeSignatureDenominator);
  const { pointerHandlers, recordMode } = useRecordButton();

  // Panel states
  const [isQuickActionsPanelOpen, setIsQuickActionsPanelOpen] = useState(false);
  const [isMarkerNavigationOpen, setIsMarkerNavigationOpen] = useState(false);

  // Refs for direct DOM updates at 60fps
  const timeRef = useRef<HTMLSpanElement>(null);
  const beatsRef = useRef<HTMLSpanElement>(null);

  // Subscribe to 60fps animation updates
  useTransportAnimation((state) => {
    if (timeRef.current) {
      timeRef.current.textContent = formatTime(state.position, { precision: 0, showSign: false });
    }
    if (beatsRef.current) {
      beatsRef.current.textContent = state.positionBeats;
    }
  }, []);

  const handleSkipToStart = () => sendCommand(transport.goStart());
  const handlePlay = () => sendCommand(play());
  const handlePause = () => sendCommand(pause());
  const handleStop = () => sendCommand(stop());

  // Double-tap handler for Quick Actions Panel
  const { onClick: handleDoubleTapCheck } = useDoubleTap({
    onDoubleTap: useCallback(() => {
      setIsQuickActionsPanelOpen(true);
    }, []),
  });

  // Long-press handler for Marker Navigation
  // Taps are forwarded to the double-tap handler
  const { handlers: timeDisplayHandlers } = useLongPress({
    onTap: handleDoubleTapCheck,
    onLongPress: useCallback(() => {
      setIsMarkerNavigationOpen(true);
    }, []),
    duration: 500,
  });

  const handleCloseQuickActionsPanel = useCallback(() => {
    setIsQuickActionsPanelOpen(false);
  }, []);

  const handleCloseMarkerNavigation = useCallback(() => {
    setIsMarkerNavigationOpen(false);
  }, []);

  const recordInactiveClass = recordMode !== 'normal'
    ? 'bg-record-dim hover:bg-record-hover ring-2 ring-record-ring'
    : 'bg-record-dim hover:bg-record-hover ring-2 ring-record-ring-dim';

  const isRight = position === 'right';

  return (
    <div className={`flex items-center justify-between bg-bg-deep border-t border-border-muted px-3 py-2 ${isRight ? 'flex-row-reverse' : ''} ${className}`}>
      {/* Transport buttons - compact row */}
      <div className="flex items-center gap-1.5">
        <CircularTransportButton onClick={handleSkipToStart} title="Skip to Start" size="sm">
          <SkipBack size={16} />
        </CircularTransportButton>

        <CircularTransportButton
          onClick={handlePlay}
          isActive={isPlaying}
          activeColor="green"
          title="Play"
          size="sm"
        >
          <Play size={16} fill={isPlaying ? 'currentColor' : 'none'} />
        </CircularTransportButton>

        <CircularTransportButton
          onClick={handlePause}
          isActive={isPaused}
          activeColor="gray"
          title="Pause"
          size="sm"
        >
          <Pause size={16} fill={isPaused ? 'currentColor' : 'none'} />
        </CircularTransportButton>

        <CircularTransportButton
          onClick={handleStop}
          isActive={isStopped}
          activeColor="gray"
          title="Stop"
          size="sm"
        >
          <Square size={14} fill={isStopped ? 'currentColor' : 'none'} />
        </CircularTransportButton>

        {/* Record - with long-press for record mode cycling */}
        <button
          {...pointerHandlers}
          title={recordModeTitle(recordMode)}
          aria-label={recordModeTitle(recordMode)}
          aria-pressed={isRecording}
          className={`
            w-10 h-10 rounded-full flex items-center justify-center
            transition-colors touch-none
            ${isRecording ? 'bg-record animate-pulse' : recordInactiveClass}
          `}
        >
          <RecordModeIcon mode={recordMode} size={16} />
        </button>
      </div>

      {/* Time display - double-tap for Quick Actions, long-press for Marker Navigation */}
      <button
        {...timeDisplayHandlers}
        className={`font-mono ${isRight ? 'text-left' : 'text-right'} hover:bg-bg-elevated/50 rounded-lg px-2 py-1 -mx-2 -my-1 transition-colors touch-none`}
        title="Double-tap for quick actions, hold for marker navigation"
        aria-label="Time display - double-tap for quick actions, hold for markers"
      >
        <div className="text-lg font-medium">
          <span ref={beatsRef} className="text-text-primary">1.1.00</span>
        </div>
        <div className="text-xs text-text-secondary">
          <span ref={timeRef}>0:00</span>
          <span className="mx-1.5">|</span>
          <span>{Math.round(bpm ?? 120)}</span>
          <span className="mx-1">|</span>
          <span>{timeSignatureNumerator}/{timeSignatureDenominator}</span>
        </div>
      </button>

      {/* Quick Actions Panel */}
      <QuickActionsPanel
        isOpen={isQuickActionsPanelOpen}
        onClose={handleCloseQuickActionsPanel}
      />

      {/* Marker Navigation Panel */}
      <MarkerNavigationPanel
        isOpen={isMarkerNavigationOpen}
        onClose={handleCloseMarkerNavigation}
      />
    </div>
  );
}
