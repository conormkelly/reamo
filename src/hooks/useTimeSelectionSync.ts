/**
 * Time Selection Sync Hook
 * Detects REAPER's current time selection on init by probing cursor positions
 */

import { useEffect, useRef, useCallback, useState } from 'react';
import { useReaperStore } from '../store';
import { useReaper } from '../components/ReaperProvider';
import * as commands from '../core/CommandBuilder';

// REAPER Actions
const GO_TO_SELECTION_START = 40630;
const GO_TO_SELECTION_END = 40631;
const GO_TO_PROJECT_START = 40042;
const GO_TO_PROJECT_END = 40043;

// Detection states
type DetectionState =
  | 'idle'
  | 'saving_position'
  | 'going_to_project_end'
  | 'checking_selection_start'
  | 'going_to_project_start'
  | 'checking_selection_end'
  | 'restoring_position'
  | 'done';

// Delay between steps (ms) - needs to be long enough for position to update
const STEP_DELAY = 100;

export interface UseTimeSelectionSyncReturn {
  /** Whether the sync is currently in progress */
  isSyncing: boolean;
}

/**
 * Hook that syncs REAPER's time selection to the store on connection
 */
export function useTimeSelectionSync(): UseTimeSelectionSyncReturn {
  const { send, connected } = useReaper();
  const positionSeconds = useReaperStore((state) => state.positionSeconds);
  const bpm = useReaperStore((state) => state.bpm);
  const setTimeSelection = useReaperStore((state) => state.setTimeSelection);

  // Syncing state for UI
  const [isSyncing, setIsSyncing] = useState(false);

  // Detection state
  const stateRef = useRef<DetectionState>('idle');
  const savedPositionRef = useRef<number>(0);
  const projectEndRef = useRef<number>(0);
  const projectStartRef = useRef<number>(0);
  const selectionStartRef = useRef<number | null>(null);
  const selectionEndRef = useRef<number | null>(null);
  const hasRunRef = useRef(false);
  const stepTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Convert seconds to beats for storage
  const secondsToBeats = useCallback(
    (seconds: number): number => {
      if (!bpm) return 0;
      return seconds * (bpm / 60);
    },
    [bpm]
  );

  // Finish syncing (success or early exit)
  const finishSync = useCallback(() => {
    stateRef.current = 'done';
    setIsSyncing(false);
  }, []);

  // Run a step after a delay
  const runStep = useCallback(
    (nextState: DetectionState, command?: string) => {
      if (stepTimeoutRef.current) {
        clearTimeout(stepTimeoutRef.current);
      }
      stepTimeoutRef.current = setTimeout(() => {
        stateRef.current = nextState;
        if (command) {
          send(command);
        }
      }, STEP_DELAY);
    },
    [send]
  );

  // Start detection when connected and have BPM
  useEffect(() => {
    if (!connected || !bpm || hasRunRef.current) return;

    // Wait a bit for initial position to settle
    const initTimeout = setTimeout(() => {
      if (stateRef.current === 'idle') {
        hasRunRef.current = true;
        savedPositionRef.current = positionSeconds;
        stateRef.current = 'saving_position';
        setIsSyncing(true);

        // Step 1: Go to project end
        runStep('going_to_project_end', commands.action(GO_TO_PROJECT_END));
      }
    }, 500);

    return () => clearTimeout(initTimeout);
  }, [connected, bpm, positionSeconds, runStep]);

  // React to position changes and advance state machine
  useEffect(() => {
    const state = stateRef.current;

    if (state === 'idle' || state === 'done' || state === 'saving_position') {
      return;
    }

    switch (state) {
      case 'going_to_project_end':
        // Record project end position, then go to selection start
        projectEndRef.current = positionSeconds;
        runStep('checking_selection_start', commands.action(GO_TO_SELECTION_START));
        break;

      case 'checking_selection_start':
        // If position changed from project end, we have a selection start
        if (Math.abs(positionSeconds - projectEndRef.current) > 0.01) {
          selectionStartRef.current = positionSeconds;
          // Continue to check selection end
          runStep('going_to_project_start', commands.action(GO_TO_PROJECT_START));
        } else {
          // No selection - early exit, restore position and finish
          runStep('restoring_position', commands.setPosition(savedPositionRef.current));
        }
        break;

      case 'going_to_project_start':
        // Record project start position, then go to selection end
        projectStartRef.current = positionSeconds;
        runStep('checking_selection_end', commands.action(GO_TO_SELECTION_END));
        break;

      case 'checking_selection_end':
        // If position changed from project start, we have a selection end
        if (Math.abs(positionSeconds - projectStartRef.current) > 0.01) {
          selectionEndRef.current = positionSeconds;
        }
        // Restore original position
        runStep('restoring_position', commands.setPosition(savedPositionRef.current));
        break;

      case 'restoring_position':
        // Done! Store the selection if we found one
        if (selectionStartRef.current !== null && selectionEndRef.current !== null) {
          const startBeats = secondsToBeats(selectionStartRef.current);
          const endBeats = secondsToBeats(selectionEndRef.current);

          // Only set if it's a valid selection (start < end)
          if (startBeats < endBeats) {
            setTimeSelection({ startBeats, endBeats });
          }
        }
        finishSync();
        break;
    }
  }, [positionSeconds, runStep, secondsToBeats, setTimeSelection, finishSync]);

  // Cleanup
  useEffect(() => {
    return () => {
      if (stepTimeoutRef.current) {
        clearTimeout(stepTimeoutRef.current);
      }
    };
  }, []);

  return { isSyncing };
}
