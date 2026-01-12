/**
 * PersistentTransport Component
 * Always-visible transport bar at the bottom of the screen
 * Contains transport controls + time display + BPM
 */

import type { ReactElement } from 'react';
import { useState, useRef, useCallback, useEffect } from 'react';
import { SkipBack, Play, Pause, Square, Circle, RefreshCw } from 'lucide-react';
import { useReaper } from './ReaperProvider';
import { useTransport } from '../hooks/useTransport';
import { useReaperStore } from '../store';
import { transport, action } from '../core/WebSocketCommands';
import { useTransportAnimation, useDoubleTap } from '../hooks';
import { formatTime } from '../utils';
import { QuickActionsPanel } from './QuickActionsPanel';

// Hold duration threshold in ms
const HOLD_THRESHOLD = 300;

export interface PersistentTransportProps {
  className?: string;
  /** Position of transport buttons - 'left' (default) or 'right' */
  position?: 'left' | 'right';
}

interface MiniTransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  title: string;
  children: React.ReactNode;
}

function MiniTransportButton({
  onClick,
  isActive = false,
  activeColor = 'gray',
  title,
  children,
}: MiniTransportButtonProps): ReactElement {
  const colorClasses = {
    green: 'bg-success',
    red: 'bg-error',
    gray: 'bg-bg-hover',
  };

  return (
    <button
      onClick={onClick}
      title={title}
      aria-label={title}
      aria-pressed={isActive}
      className={`
        w-10 h-10 rounded-full flex items-center justify-center
        transition-colors
        ${isActive ? colorClasses[activeColor] : 'bg-bg-elevated hover:bg-bg-hover'}
      `}
    >
      {children}
    </button>
  );
}

export function PersistentTransport({ className = '', position = 'left' }: PersistentTransportProps): ReactElement {
  const { sendCommand } = useReaper();
  const { isPlaying, isPaused, isStopped, isRecording, play, pause, stop, record } = useTransport();
  const isAutoPunch = useReaperStore((state) => state.isAutoPunch);
  const bpm = useReaperStore((state) => state.bpm);
  const timeSignatureNumerator = useReaperStore((state) => state.timeSignatureNumerator);
  const timeSignatureDenominator = useReaperStore((state) => state.timeSignatureDenominator);

  // Quick Actions Panel state
  const [isQuickActionsPanelOpen, setIsQuickActionsPanelOpen] = useState(false);

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

  // Long-press state for Record button
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasHoldRef = useRef(false);

  const handleSkipToStart = () => sendCommand(transport.goStart());
  const handlePlay = () => sendCommand(play());
  const handlePause = () => sendCommand(pause());
  const handleStop = () => sendCommand(stop());

  // Record button long-press handlers
  const handleRecordPointerDown = useCallback(() => {
    wasHoldRef.current = false;
    holdTimerRef.current = setTimeout(() => {
      wasHoldRef.current = true;
      if (isAutoPunch) {
        sendCommand(action.execute(40252)); // Set record mode to normal
      } else {
        sendCommand(action.execute(40076)); // Set record mode to time selection auto-punch
      }
    }, HOLD_THRESHOLD);
  }, [sendCommand, isAutoPunch]);

  const handleRecordPointerUp = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
    if (!wasHoldRef.current) {
      sendCommand(record());
    }
  }, [sendCommand, record]);

  const handleRecordPointerCancel = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
  }, []);

  // Cleanup timer on unmount
  useEffect(() => {
    return () => {
      if (holdTimerRef.current) {
        clearTimeout(holdTimerRef.current);
      }
    };
  }, []);

  // Double-tap handler for Quick Actions Panel
  const { onClick: handleTimeDisplayClick } = useDoubleTap({
    onDoubleTap: useCallback(() => {
      setIsQuickActionsPanelOpen(true);
    }, []),
  });

  const handleCloseQuickActionsPanel = useCallback(() => {
    setIsQuickActionsPanelOpen(false);
  }, []);

  const recordInactiveClass = isAutoPunch
    ? 'bg-record-dim hover:bg-record-hover ring-2 ring-record-ring'
    : 'bg-record-dim hover:bg-record-hover ring-2 ring-record-ring-dim';

  const isRight = position === 'right';

  return (
    <div className={`flex items-center justify-between bg-bg-deep border-t border-border-muted px-3 py-2 ${isRight ? 'flex-row-reverse' : ''} ${className}`}>
      {/* Transport buttons - compact row */}
      <div className="flex items-center gap-1.5">
        <MiniTransportButton onClick={handleSkipToStart} title="Skip to Start">
          <SkipBack size={16} />
        </MiniTransportButton>

        <MiniTransportButton
          onClick={handlePlay}
          isActive={isPlaying}
          activeColor="green"
          title="Play"
        >
          <Play size={16} fill={isPlaying ? 'currentColor' : 'none'} />
        </MiniTransportButton>

        <MiniTransportButton
          onClick={handlePause}
          isActive={isPaused}
          activeColor="gray"
          title="Pause"
        >
          <Pause size={16} fill={isPaused ? 'currentColor' : 'none'} />
        </MiniTransportButton>

        <MiniTransportButton
          onClick={handleStop}
          isActive={isStopped}
          activeColor="gray"
          title="Stop"
        >
          <Square size={14} fill={isStopped ? 'currentColor' : 'none'} />
        </MiniTransportButton>

        {/* Record - with long-press for auto-punch toggle */}
        <button
          onPointerDown={handleRecordPointerDown}
          onPointerUp={handleRecordPointerUp}
          onPointerCancel={handleRecordPointerCancel}
          onPointerLeave={handleRecordPointerCancel}
          title={isAutoPunch ? "Record (Auto-Punch) - hold to toggle mode" : "Record - hold to toggle auto-punch"}
          aria-label={isAutoPunch ? "Record (Auto-Punch mode)" : "Record"}
          aria-pressed={isRecording}
          className={`
            w-10 h-10 rounded-full flex items-center justify-center
            transition-colors touch-none
            ${isRecording ? 'bg-record animate-pulse' : recordInactiveClass}
          `}
        >
          {isAutoPunch ? (
            <RefreshCw size={16} strokeWidth={2.5} />
          ) : (
            <Circle size={16} fill="currentColor" />
          )}
        </button>
      </div>

      {/* Time display - compact, double-tap to open Quick Actions */}
      <button
        onClick={handleTimeDisplayClick}
        className={`font-mono ${isRight ? 'text-left' : 'text-right'} hover:bg-bg-elevated/50 rounded-lg px-2 py-1 -mx-2 -my-1 transition-colors`}
        title="Double-tap for quick actions"
        aria-label="Time display - double-tap for quick actions"
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
    </div>
  );
}
