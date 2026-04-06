/**
 * useRecordButton hook
 * Shared long-press logic for record button across all transport contexts.
 * Long-press cycles through record modes: normal → timeSelection → selectedItems → normal
 * Short-press toggles recording on/off.
 */

import { useRef, useCallback, useEffect } from 'react';
import { useReaper } from '../components/ReaperProvider';
import { useTransport } from './useTransport';
import { useReaperStore } from '../store';
import { action } from '../core/WebSocketCommands';
import type { RecordMode } from '../core/types';

const HOLD_THRESHOLD = 300;

const MODE_TITLES: Record<RecordMode, string> = {
  normal: 'Record - hold to cycle mode',
  timeSelection: 'Record (Time Sel Auto-Punch) - hold to cycle mode',
  selectedItems: 'Record (Item Auto-Punch) - hold to cycle mode',
};

export function recordModeTitle(mode: RecordMode): string {
  return MODE_TITLES[mode];
}

export interface UseRecordButtonReturn {
  /** Pointer event handlers to spread onto the button element */
  pointerHandlers: {
    onPointerDown: () => void;
    onPointerUp: () => void;
    onPointerCancel: () => void;
    onPointerLeave: () => void;
  };
  /** Current record mode from REAPER state */
  recordMode: RecordMode;
  /** Whether REAPER is currently recording */
  isRecording: boolean;
}

export function useRecordButton(): UseRecordButtonReturn {
  const { sendCommand } = useReaper();
  const { isRecording, record } = useTransport();
  const recordMode = useReaperStore((state) => state.recordMode);

  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasHoldRef = useRef(false);

  const handlePointerDown = useCallback(() => {
    wasHoldRef.current = false;
    holdTimerRef.current = setTimeout(() => {
      wasHoldRef.current = true;
      // Cycle: normal → timeSelection → selectedItems → normal
      if (recordMode === 'normal') {
        sendCommand(action.execute(40076)); // time selection auto-punch
      } else if (recordMode === 'timeSelection') {
        sendCommand(action.execute(40253)); // selected items auto-punch
      } else {
        sendCommand(action.execute(40252)); // normal
      }
    }, HOLD_THRESHOLD);
  }, [sendCommand, recordMode]);

  const handlePointerUp = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
    if (!wasHoldRef.current) {
      sendCommand(record());
    }
  }, [sendCommand, record]);

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

  return {
    pointerHandlers: {
      onPointerDown: handlePointerDown,
      onPointerUp: handlePointerUp,
      onPointerCancel: handlePointerCancel,
      onPointerLeave: handlePointerCancel,
    },
    recordMode,
    isRecording,
  };
}
