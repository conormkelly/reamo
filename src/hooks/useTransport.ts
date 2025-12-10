/**
 * Transport Hook
 * Provides transport state and control actions
 */

import { useCallback } from 'react';
import { useReaperStore } from '../store';
import type { PlayState } from '../core/types';
import * as commands from '../core/CommandBuilder';

export interface UseTransportReturn {
  // State
  playState: PlayState;
  isPlaying: boolean;
  isPaused: boolean;
  isStopped: boolean;
  isRecording: boolean;
  positionSeconds: number;
  positionString: string;
  positionBeats: string;
  isRepeat: boolean;

  // Actions (requires send function from useReaperConnection)
  play: () => string;
  pause: () => string;
  stop: () => string;
  record: () => string;
  toggleRepeat: () => string;
  seekTo: (seconds: number) => string;
  seekToString: (position: string) => string;
  prevMarker: () => string;
  nextMarker: () => string;
}

/**
 * Hook for transport state and controls
 * Returns command strings - use with useReaperConnection's send() function
 */
export function useTransport(): UseTransportReturn {
  // State selectors
  const playState = useReaperStore((state) => state.playState);
  const positionSeconds = useReaperStore((state) => state.positionSeconds);
  const positionString = useReaperStore((state) => state.positionString);
  const positionBeats = useReaperStore((state) => state.positionBeats);
  const isRepeat = useReaperStore((state) => state.isRepeat);

  // Derived state
  const isPlaying = playState === 1;
  const isPaused = playState === 2 || playState === 6;
  const isStopped = playState === 0;
  const isRecording = playState === 5 || playState === 6;

  // Command builders
  const play = useCallback(() => commands.play(), []);
  const pause = useCallback(() => commands.pause(), []);
  const stop = useCallback(() => commands.stop(), []);
  const record = useCallback(() => commands.record(), []);
  const toggleRepeat = useCallback(() => commands.toggleRepeat(), []);
  const seekTo = useCallback(
    (seconds: number) => commands.setPosition(seconds),
    []
  );
  const seekToString = useCallback(
    (position: string) => commands.setPositionString(position),
    []
  );
  const prevMarker = useCallback(() => commands.prevMarker(), []);
  const nextMarker = useCallback(() => commands.nextMarker(), []);

  return {
    playState,
    isPlaying,
    isPaused,
    isStopped,
    isRecording,
    positionSeconds,
    positionString,
    positionBeats,
    isRepeat,
    play,
    pause,
    stop,
    record,
    toggleRepeat,
    seekTo,
    seekToString,
    prevMarker,
    nextMarker,
  };
}
