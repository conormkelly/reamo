/**
 * ClockView - Big transport, BPM, bar.beat
 * Dynamically sizes to fill available space without overflow
 * Uses CSS clamp() and container-relative sizing for responsive layout
 */

import { useRef, useCallback, type ReactElement } from 'react';
import { Play, Pause, Square, Circle, SkipBack, RefreshCw } from 'lucide-react';
import { useReaper } from '../../components/ReaperProvider';
import { useTransport, useTransportAnimation, useTransportSync } from '../../hooks';
import { useReaperStore } from '../../store';
import { transport, action } from '../../core/WebSocketCommands';
import { formatTime } from '../../utils';

// Hold duration for record button mode toggle
const HOLD_THRESHOLD = 300;


interface BigTransportButtonProps {
  onClick: () => void;
  isActive?: boolean;
  activeColor?: 'green' | 'red' | 'gray';
  title: string;
  children: React.ReactNode;
}

function BigTransportButton({
  onClick,
  isActive = false,
  activeColor = 'gray',
  title,
  children,
}: BigTransportButtonProps): ReactElement {
  const colorClasses = {
    green: 'bg-green-500',
    red: 'bg-red-500',
    gray: 'bg-gray-600',
  };

  return (
    <button
      onClick={onClick}
      title={title}
      className={`
        aspect-square rounded-full flex items-center justify-center
        transition-colors shadow-lg
        ${isActive ? colorClasses[activeColor] : 'bg-gray-700 hover:bg-gray-600 active:bg-gray-500'}
      `}
      style={{
        // Dynamic button size: 12-15% of container height, clamped between 48px and 112px
        width: 'clamp(48px, 12cqh, 112px)',
        height: 'clamp(48px, 12cqh, 112px)',
      }}
    >
      {children}
    </button>
  );
}

export function ClockView(): ReactElement {
  const { sendCommand } = useReaper();
  const { isPlaying, isPaused, isStopped, isRecording, play, pause, stop, record } = useTransport();
  const isAutoPunch = useReaperStore((state) => state.isAutoPunch);
  const bpm = useReaperStore((state) => state.bpm);

  // Refs for direct DOM updates at 60fps
  const timeRef = useRef<HTMLSpanElement>(null);
  const beatsRef = useRef<HTMLSpanElement>(null);

  // Subscribe to 60fps animation updates for time display (seconds)
  useTransportAnimation((state) => {
    if (timeRef.current) {
      timeRef.current.textContent = formatTime(state.position, { precision: 1, showSign: false });
    }
  }, []);

  // Subscribe to transport sync for bar.beat.ticks (server-computed, clock-synchronized)
  useTransportSync((state) => {
    if (beatsRef.current) {
      beatsRef.current.textContent = state.barBeatTicks;
    }
  }, []);

  // Transport handlers
  const handleSkipToStart = () => sendCommand(transport.goStart());
  const handlePlay = () => sendCommand(play());
  const handlePause = () => sendCommand(pause());
  const handleStop = () => sendCommand(stop());

  // Record button long-press handlers
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasHoldRef = useRef(false);

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

  const recordInactiveClass = isAutoPunch
    ? 'bg-red-900/50 hover:bg-red-800/70 ring-2 ring-red-500/50'
    : 'bg-red-900/50 hover:bg-red-800/70 ring-2 ring-red-500/30';

  // Icon size scales with button (roughly 50% of button size)
  const iconStyle = {
    width: 'clamp(24px, 6cqh, 56px)',
    height: 'clamp(24px, 6cqh, 56px)',
  };

  return (
    <div
      data-view="clock"
      className="h-full w-full bg-black text-white flex flex-col items-center justify-center p-2 select-none overflow-hidden"
      style={{ containerType: 'size' }}
    >
      {/* Bar.Beat Display - scales with container, capped by width for long bar numbers
          Formula: text_width ≈ 6 × font_size for 10-char monospace string
          To fit 10 chars: font_size ≤ container_width / 6 ≈ 16cqw */}
      <div
        className="text-center font-mono font-bold tracking-tight"
        style={{
          fontSize: 'clamp(2.5rem, min(25cqh, 16cqw), 12rem)',
          lineHeight: 1.1,
          marginBottom: 'clamp(0.25rem, 1cqh, 1.5rem)',
        }}
      >
        <span ref={beatsRef}>1.1.00</span>
      </div>

      {/* Time Display - precision: 1 (deciseconds) prevents visual stutter from rapid changes */}
      <div
        className="text-center font-mono text-gray-300"
        style={{
          fontSize: 'clamp(1.5rem, 12cqh, 6rem)',
          lineHeight: 1.2,
          marginBottom: 'clamp(0.125rem, 0.5cqh, 1rem)',
        }}
      >
        <span ref={timeRef}>0:00.0</span>
      </div>

      {/* BPM Display */}
      <div
        className="text-center font-bold text-gray-400"
        style={{
          fontSize: 'clamp(1.25rem, 8cqh, 4rem)',
          lineHeight: 1.2,
          marginBottom: 'clamp(0.5rem, 3cqh, 2.5rem)',
        }}
      >
        {Math.round(bpm ?? 120)} <span style={{ fontSize: '0.75em' }}>BPM</span>
      </div>

      {/* Transport Controls - horizontally centered, dynamic sizing */}
      <div
        className="flex items-center justify-center"
        style={{ gap: 'clamp(6px, 1.5cqh, 32px)' }}
      >
        <BigTransportButton onClick={handleSkipToStart} title="Skip to Start">
          <SkipBack style={iconStyle} />
        </BigTransportButton>

        <BigTransportButton
          onClick={handlePlay}
          isActive={isPlaying}
          activeColor="green"
          title="Play"
        >
          <Play style={iconStyle} fill={isPlaying ? 'currentColor' : 'none'} />
        </BigTransportButton>

        <BigTransportButton
          onClick={handlePause}
          isActive={isPaused}
          activeColor="gray"
          title="Pause"
        >
          <Pause style={iconStyle} fill={isPaused ? 'currentColor' : 'none'} />
        </BigTransportButton>

        <BigTransportButton
          onClick={handleStop}
          isActive={isStopped}
          activeColor="gray"
          title="Stop"
        >
          <Square style={{ ...iconStyle, width: 'clamp(20px, 5cqh, 48px)', height: 'clamp(20px, 5cqh, 48px)' }} fill={isStopped ? 'currentColor' : 'none'} />
        </BigTransportButton>

        {/* Record - with long-press for auto-punch toggle */}
        <button
          onPointerDown={handleRecordPointerDown}
          onPointerUp={handleRecordPointerUp}
          onPointerCancel={handleRecordPointerCancel}
          onPointerLeave={handleRecordPointerCancel}
          title={isAutoPunch ? "Record (Auto-Punch) - hold to toggle mode" : "Record - hold to toggle auto-punch"}
          className={`
            aspect-square rounded-full flex items-center justify-center
            transition-colors shadow-lg touch-none select-none
            ${isRecording ? 'bg-red-500 animate-pulse' : recordInactiveClass}
          `}
          style={{
            width: 'clamp(48px, 12cqh, 112px)',
            height: 'clamp(48px, 12cqh, 112px)',
          }}
        >
          {isAutoPunch ? (
            <RefreshCw style={iconStyle} strokeWidth={2.5} />
          ) : (
            <Circle style={iconStyle} fill="currentColor" />
          )}
        </button>
      </div>

      {/* Recording indicator */}
      {isRecording && (
        <div
          className="flex items-center text-red-400 font-medium"
          style={{
            marginTop: 'clamp(0.5rem, 2cqh, 2rem)',
            gap: 'clamp(0.375rem, 1cqh, 0.75rem)',
            fontSize: 'clamp(0.875rem, 4cqh, 1.875rem)',
          }}
        >
          <div
            className="rounded-full bg-red-500 animate-pulse"
            style={{
              width: 'clamp(10px, 2cqh, 20px)',
              height: 'clamp(10px, 2cqh, 20px)',
            }}
          />
          <span>RECORDING</span>
        </div>
      )}
    </div>
  );
}
