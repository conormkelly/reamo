/**
 * Metronome Button with Long-Press Volume Control
 * - Tap: Toggle metronome on/off
 * - Long press: Open volume adjustment dialog with +/- buttons
 */

import { useState, useRef, useCallback, useEffect, type ReactElement } from 'react';
import { Gauge, Minus, Plus } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { action, metronome } from '../../core/WebSocketCommands';

// Hold duration threshold in ms
const HOLD_THRESHOLD = 300;

// SWS action IDs for metronome volume
const SWS_METRO_VOL_DOWN = '_S&M_METRO_VOL_DOWN';
const SWS_METRO_VOL_UP = '_S&M_METRO_VOL_UP';

// SWS action IDs for count-in
const SWS_COUNT_IN_RECORD = '_SWS_AWCOUNTRECTOG';
const SWS_COUNT_IN_PLAYBACK = '_SWS_AWCOUNTPLAYTOG';

export interface MetronomeButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Metronome button with long-press for volume control
 * - Tap: Toggle metronome on/off
 * - Long press: Open volume adjustment dialog with +/- buttons
 */
export function MetronomeButton({
  className = '',
  size = 'md',
}: MetronomeButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const isMetronome = useReaperStore((state) => state.isMetronome);
  const isCountInRecord = useReaperStore((state) => state.isCountInRecord);
  const isCountInPlayback = useReaperStore((state) => state.isCountInPlayback);

  // Long-press state
  const [showDialog, setShowDialog] = useState(false);
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasHoldRef = useRef(false);

  const handlePointerDown = useCallback(() => {
    wasHoldRef.current = false;
    holdTimerRef.current = setTimeout(() => {
      wasHoldRef.current = true;
      setShowDialog(true);
    }, HOLD_THRESHOLD);
  }, []);

  const handlePointerUp = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
    // If it wasn't a hold, toggle metronome
    if (!wasHoldRef.current && !showDialog) {
      sendCommand(metronome.toggle());
    }
  }, [sendCommand, showDialog]);

  const handlePointerCancel = useCallback(() => {
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

  const handleVolumeUp = useCallback(() => {
    sendCommand(action.executeByName(SWS_METRO_VOL_UP));
  }, [sendCommand]);

  const handleVolumeDown = useCallback(() => {
    sendCommand(action.executeByName(SWS_METRO_VOL_DOWN));
  }, [sendCommand]);

  const handleToggleCountInRecord = useCallback(() => {
    sendCommand(action.executeByName(SWS_COUNT_IN_RECORD));
  }, [sendCommand]);

  const handleToggleCountInPlayback = useCallback(() => {
    sendCommand(action.executeByName(SWS_COUNT_IN_PLAYBACK));
  }, [sendCommand]);

  const handleOverlayClick = useCallback(
    (e: React.MouseEvent) => {
      if (e.target === e.currentTarget) {
        setShowDialog(false);
      }
    },
    []
  );

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  const activeClass = isMetronome
    ? 'bg-metronome-bg text-metronome hover:bg-metronome-hover'
    : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover';

  return (
    <>
      <button
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerCancel}
        onPointerLeave={handlePointerCancel}
        title="Toggle Metronome - hold for volume"
        aria-label="Toggle Metronome"
        aria-pressed={isMetronome}
        className={`
          ${sizeClasses[size]}
          ${activeClass}
          rounded font-medium transition-colors touch-none select-none
          ${className}
        `}
      >
        <Gauge size={16} className="inline-block align-middle mr-1" />
        <span className="align-middle">Click</span>
      </button>

      {/* Volume Dialog */}
      {showDialog && (
        <div
          className="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
          onClick={handleOverlayClick}
        >
          <div className="bg-bg-surface rounded-lg p-4 shadow-xl border border-border-subtle min-w-[200px]">
            {/* Volume Section */}
            <div className="text-sm text-text-secondary mb-3 text-center">Metronome Volume</div>
            <div className="flex items-center justify-center gap-4">
              <button
                onClick={handleVolumeDown}
                className="w-14 h-14 rounded-lg bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled flex items-center justify-center text-2xl"
              >
                <Minus size={28} />
              </button>
              <button
                onClick={handleVolumeUp}
                className="w-14 h-14 rounded-lg bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled flex items-center justify-center text-2xl"
              >
                <Plus size={28} />
              </button>
            </div>
            <div className="text-xs text-text-muted mt-2 text-center">
              ~0.2 dB per tap
            </div>

            {/* Divider */}
            <div className="border-t border-border-subtle my-4" />

            {/* Count-In Section */}
            <div className="text-sm text-text-secondary mb-3 text-center">Count-In</div>
            <div className="flex items-center justify-center gap-3">
              <button
                onClick={handleToggleCountInRecord}
                className={`px-4 py-2 rounded-lg font-medium transition-colors ${
                  isCountInRecord
                    ? 'bg-count-in-record-bg text-count-in-record-text hover:bg-count-in-record-hover'
                    : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                }`}
              >
                Record
              </button>
              <button
                onClick={handleToggleCountInPlayback}
                className={`px-4 py-2 rounded-lg font-medium transition-colors ${
                  isCountInPlayback
                    ? 'bg-count-in-play-bg text-count-in-play-text hover:bg-count-in-play-hover'
                    : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                }`}
              >
                Playback
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
