/**
 * Tap Tempo Button Component
 * Displays project BPM (calculated from BEATPOS) and allows tapping to set tempo
 * Long press opens a tempo input dialog
 *
 * Dialog renders via portal to document.body to escape stacking contexts.
 */

import { useState, useRef, useCallback, useEffect, type ReactElement } from 'react';
import { createPortal } from 'react-dom';
import { Minus, Plus } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { tempo } from '../../core/WebSocketCommands';

// Hold duration threshold in ms
const HOLD_THRESHOLD = 300;

export interface TapTempoButtonProps {
  className?: string;
  /** Button size */
  size?: 'sm' | 'md' | 'lg';
  /** Show "BPM" label after number */
  showLabel?: boolean;
}

/**
 * Button that displays project BPM and triggers tap tempo
 *
 * - Tap: sends tap tempo action to REAPER
 * - Long press: opens tempo input dialog to set exact BPM
 */
export function TapTempoButton({
  className = '',
  size = 'md',
  showLabel = true,
}: TapTempoButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const bpm = useReaperStore((state) => state.bpm);
  const setBpm = useReaperStore((state) => state.setBpm);

  // Gesture state
  const [showDialog, setShowDialog] = useState(false);
  const [inputValue, setInputValue] = useState('');
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const focusTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasHoldRef = useRef(false);
  const inputRef = useRef<HTMLInputElement>(null);

  // Initialize input value when dialog opens
  useEffect(() => {
    if (showDialog) {
      setInputValue(bpm !== null ? String(Math.round(bpm)) : '120');
      // Focus and select input after a brief delay for animation
      focusTimerRef.current = setTimeout(() => {
        inputRef.current?.focus();
        inputRef.current?.select();
      }, 50);
    }
    return () => {
      if (focusTimerRef.current) {
        clearTimeout(focusTimerRef.current);
      }
    };
  }, [showDialog, bpm]);

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
    // If it wasn't a hold, send tap tempo
    if (!wasHoldRef.current && !showDialog) {
      sendCommand(tempo.tap());
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

  const applyTempo = useCallback(
    (newBpm: number) => {
      const clampedBpm = Math.max(2, Math.min(960, Math.round(newBpm)));
      // Optimistic update - show new BPM immediately (works even at position 0)
      setBpm(clampedBpm);
      setInputValue(String(clampedBpm));
      // Send tempo change (WebSocket push will update regions/markers automatically)
      sendCommand(tempo.set(clampedBpm));
    },
    [sendCommand, setBpm]
  );

  const handleInputChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const value = e.target.value.replace(/[^0-9]/g, '');
      setInputValue(value);
    },
    []
  );

  const handleInputKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLInputElement>) => {
      if (e.key === 'Enter') {
        const newBpm = parseInt(inputValue, 10);
        if (!isNaN(newBpm)) {
          applyTempo(newBpm);
        }
        setShowDialog(false);
      } else if (e.key === 'Escape') {
        setShowDialog(false);
      }
    },
    [inputValue, applyTempo]
  );

  const handleIncrement = useCallback(() => {
    const currentBpm = parseInt(inputValue, 10) || (bpm !== null ? Math.round(bpm) : 120);
    applyTempo(currentBpm + 1);
  }, [inputValue, bpm, applyTempo]);

  const handleDecrement = useCallback(() => {
    const currentBpm = parseInt(inputValue, 10) || (bpm !== null ? Math.round(bpm) : 120);
    applyTempo(currentBpm - 1);
  }, [inputValue, bpm, applyTempo]);

  const handleOverlayClick = useCallback(
    (e: React.MouseEvent) => {
      if (e.target === e.currentTarget) {
        // Clicking outside the dialog - apply value and close
        const newBpm = parseInt(inputValue, 10);
        if (!isNaN(newBpm)) {
          applyTempo(newBpm);
        }
        setShowDialog(false);
      }
    },
    [inputValue, applyTempo]
  );

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm min-w-16',
    md: 'px-3 py-2 min-w-20',
    lg: 'px-4 py-3 text-lg min-w-24',
  };

  return (
    <>
      <button
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerCancel}
        onPointerLeave={handlePointerCancel}
        title="Tap Tempo - tap repeatedly to set BPM, hold to enter manually"
        className={`
          ${sizeClasses[size]}
          bg-bg-elevated text-text-primary hover:bg-bg-hover active:bg-bg-disabled
          rounded font-medium font-mono transition-colors touch-none
          ${className}
        `}
      >
        {bpm !== null ? Math.round(bpm) : '-'}
        {showLabel ? ' BPM' : ''}
      </button>

      {/* Tempo Input Dialog - portaled to body */}
      {showDialog && createPortal(
        <div
          className="fixed inset-0 bg-black/50 flex items-center justify-center z-modal"
          onClick={handleOverlayClick}
        >
          <div className="bg-bg-surface rounded-lg p-4 shadow-xl border border-border-subtle">
            <div className="text-sm text-text-secondary mb-2 text-center">Set Tempo</div>
            <div className="flex items-center gap-2">
              <button
                onClick={handleDecrement}
                className="w-10 h-10 rounded bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled flex items-center justify-center"
              >
                <Minus size={20} />
              </button>
              <input
                ref={inputRef}
                type="text"
                inputMode="numeric"
                pattern="[0-9]*"
                value={inputValue}
                onChange={handleInputChange}
                onKeyDown={handleInputKeyDown}
                className="w-20 h-10 text-center text-xl font-mono bg-bg-deep border border-border-default rounded focus:border-primary focus:outline-none"
              />
              <button
                onClick={handleIncrement}
                className="w-10 h-10 rounded bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled flex items-center justify-center"
              >
                <Plus size={20} />
              </button>
            </div>
            <div className="text-xs text-text-muted mt-2 text-center">BPM (2-960)</div>
          </div>
        </div>,
        document.body
      )}
    </>
  );
}
