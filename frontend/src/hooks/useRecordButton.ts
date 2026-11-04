/**
 * useRecordButton hook
 * The transport Record button's gestures, shared by every transport.
 * A tap toggles recording. A hold sets the next record mode:
 * normal → timeSelection → selectedItems → normal.
 *
 * useLongPress tells the two apart, so a press counts only when it starts and
 * ends on the button with the primary button, held still. Anything else (a
 * release with no press on the button, a drag, a right-click or Ctrl+click)
 * sends nothing, because a stray tap here starts a take.
 */

import { useCallback } from 'react';
import { useReaper } from './useReaper';
import { useTransport } from './useTransport';
import { useLongPress, type UseLongPressResult } from './useLongPress';
import { useReaperStore } from '../store';
import { action } from '../core/WebSocketCommands';
import type { RecordMode } from '../core/types';

/** How long, in ms, a press is held before it sets the next record mode. */
const HOLD_THRESHOLD = 300;

/** The REAPER action a hold sends from each mode, to set the next one. */
const NEXT_MODE_ACTION: Record<RecordMode, number> = {
  normal: 40076, // Record mode: time selection auto-punch
  timeSelection: 40253, // Record mode: auto-punch selected items
  selectedItems: 40252, // Record mode: normal
};

const MODE_TITLES: Record<RecordMode, string> = {
  normal: 'Record - hold to cycle mode',
  timeSelection: 'Record (Time Sel Auto-Punch) - hold to cycle mode',
  selectedItems: 'Record (Item Auto-Punch) - hold to cycle mode',
};

export function recordModeTitle(mode: RecordMode): string {
  return MODE_TITLES[mode];
}

export interface UseRecordButtonReturn {
  /** Event handlers to spread onto the button element */
  handlers: UseLongPressResult['handlers'];
  /** Current record mode from REAPER state */
  recordMode: RecordMode;
  /** Whether REAPER is currently recording */
  isRecording: boolean;
}

export function useRecordButton(): UseRecordButtonReturn {
  const { sendCommand } = useReaper();
  const { isRecording, record } = useTransport();
  const recordMode = useReaperStore((state) => state.recordMode);

  const onTap = useCallback(() => {
    sendCommand(record());
  }, [sendCommand, record]);

  // Steps from the mode REAPER reports when the hold fires, which can differ
  // from the mode when the press began.
  const onLongPress = useCallback(() => {
    const mode = useReaperStore.getState().recordMode;
    sendCommand(action.execute(NEXT_MODE_ACTION[mode]));
  }, [sendCommand]);

  const { handlers } = useLongPress({ onTap, onLongPress, duration: HOLD_THRESHOLD });

  return { handlers, recordMode, isRecording };
}
