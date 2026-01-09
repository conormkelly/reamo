/**
 * Transport Hook
 * Provides transport state and control actions
 *
 * @example
 * ```tsx
 * function TransportControls() {
 *   const { sendCommand } = useReaper();
 *   const { isPlaying, play, stop, positionBeats } = useTransport();
 *
 *   return (
 *     <div>
 *       <span>{positionBeats}</span>
 *       <button onClick={() => sendCommand(isPlaying ? stop() : play())}>
 *         {isPlaying ? 'Stop' : 'Play'}
 *       </button>
 *     </div>
 *   );
 * }
 * ```
 */

import { useCallback } from 'react';
import { useReaperStore } from '../store';
import type { PlayState } from '../core/types';
import { transport, repeat, marker } from '../core/WebSocketCommands';
import type { WSCommand } from '../core/WebSocketCommands';

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

  // Actions - return WSCommand objects for use with sendCommand
  play: () => WSCommand;
  pause: () => WSCommand;
  stop: () => WSCommand;
  record: () => WSCommand;
  toggleRepeat: () => WSCommand;
  seekTo: (seconds: number) => WSCommand;
  prevMarker: () => WSCommand;
  nextMarker: () => WSCommand;
}

/**
 * Hook for transport state and controls
 * Returns WSCommand objects - use with useReaperConnection's sendCommand()
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

  // Command builders - return WSCommand objects
  const play = useCallback(() => transport.play(), []);
  const pause = useCallback(() => transport.pause(), []);
  const stop = useCallback(() => transport.stop(), []);
  const record = useCallback(() => transport.record(), []);
  const toggleRepeat = useCallback(() => repeat.toggle(), []);
  const seekTo = useCallback(
    (seconds: number) => transport.seek(seconds),
    []
  );
  const prevMarker = useCallback(() => marker.prev(), []);
  const nextMarker = useCallback(() => marker.next(), []);

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
    prevMarker,
    nextMarker,
  };
}
