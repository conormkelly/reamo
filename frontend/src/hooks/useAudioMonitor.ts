/**
 * Audio Monitor Hook
 * Manages the audio monitoring lifecycle:
 * - Sends audio/startStream command, gets sampleRate from response
 * - Creates AudioStreamManager at server's sample rate
 * - Wires binary WebSocket frames to the AudioWorklet pipeline
 * - Handles reconnect (auto-resume if previously requested)
 * - Handles visibilitychange (stop when backgrounded, resume when foregrounded)
 */

import { useEffect, useRef, useCallback } from 'react';
import { useReaperStore } from '../store';
import { AudioStreamManager } from '../audio/AudioStreamManager';
import {
  sendCommandAsync,
  isConnected,
} from '../core/websocketActor';
import { audio } from '../core/WebSocketCommands';

/**
 * Set the global binary WebSocket handler.
 * The websocketMachine routes ArrayBuffer frames to window.__wsBinaryHandler.
 */
function setBinaryHandler(handler: ((data: ArrayBuffer) => void) | null): void {
  (window as unknown as { __wsBinaryHandler?: (data: ArrayBuffer) => void }).__wsBinaryHandler =
    handler ?? undefined;
}

export interface UseAudioMonitorReturn {
  /** Start audio monitoring */
  startMonitoring: () => void;
  /** Stop audio monitoring */
  stopMonitoring: () => void;
  /** Whether monitoring is active (buffering or streaming) */
  isActive: boolean;
  /** Whether the user has requested monitoring (persists across reconnects) */
  isRequested: boolean;
}

export function useAudioMonitor(): UseAudioMonitorReturn {
  const managerRef = useRef<AudioStreamManager | null>(null);
  const startingRef = useRef(false);

  // Store state
  const audioMonitorState = useReaperStore((s) => s.audioMonitorState);
  const audioMonitorRequested = useReaperStore((s) => s.audioMonitorRequested);
  const connected = useReaperStore((s) => s.connected);

  // Store actions
  const setAudioMonitorState = useReaperStore((s) => s.setAudioMonitorState);
  const setAudioMonitorRequested = useReaperStore((s) => s.setAudioMonitorRequested);

  /** Start the audio pipeline: unlock audio → send command → start worklet */
  const startPipeline = useCallback(async () => {
    if (startingRef.current) return;
    if (!isConnected()) return;

    startingRef.current = true;

    // Create manager if needed
    if (!managerRef.current) {
      managerRef.current = new AudioStreamManager(
        (state) => setAudioMonitorState(state),
      );
    }

    // CRITICAL: Unlock iOS audio session synchronously in the user gesture handler.
    // AudioContext.resume() must be called within the synchronous portion of a
    // user-initiated event. Do this BEFORE any async work.
    managerRef.current.unlockAudio();

    try {
      // Send startStream command and get sample rate from response
      const response = await sendCommandAsync(
        audio.startStream().command,
        audio.startStream().params,
      ) as { success?: boolean; payload?: { sampleRate?: number }; error?: { message?: string } };

      if (!response.success || !response.payload?.sampleRate) {
        console.error('[AudioMonitor] startStream failed:', response.error?.message);
        setAudioMonitorState('error');
        startingRef.current = false;
        return;
      }

      const sampleRate = response.payload.sampleRate;

      // Wire binary handler BEFORE starting (so frames aren't dropped during buffering)
      setBinaryHandler((data) => managerRef.current?.handleAudioFrame(data));

      // Start the worklet pipeline (may recreate AudioContext at correct sample rate)
      await managerRef.current.start(sampleRate);
    } catch (err) {
      console.error('[AudioMonitor] Failed to start:', err);
      setAudioMonitorState('error');
    } finally {
      startingRef.current = false;
    }
  }, [setAudioMonitorState]);

  /** Stop the audio pipeline: send command → tear down AudioContext → remove binary handler */
  const stopPipeline = useCallback(() => {
    setBinaryHandler(null);

    if (managerRef.current) {
      managerRef.current.stop();
      managerRef.current = null;
    }

    // Fire-and-forget stop command (best effort)
    if (isConnected()) {
      sendCommandAsync(
        audio.stopStream().command,
        audio.stopStream().params,
      ).catch(() => {});
    }
  }, []);

  // Public API
  const startMonitoring = useCallback(() => {
    setAudioMonitorRequested(true);
    startPipeline();
  }, [setAudioMonitorRequested, startPipeline]);

  const stopMonitoring = useCallback(() => {
    setAudioMonitorRequested(false);
    stopPipeline();
    setAudioMonitorState('stopped');
  }, [setAudioMonitorRequested, stopPipeline, setAudioMonitorState]);

  // Auto-resume on reconnect if previously requested
  useEffect(() => {
    if (connected && audioMonitorRequested && audioMonitorState === 'stopped') {
      startPipeline();
    }
  }, [connected, audioMonitorRequested, audioMonitorState, startPipeline]);

  // Stop on disconnect (clean up client-side resources)
  useEffect(() => {
    if (!connected && managerRef.current) {
      setBinaryHandler(null);
      managerRef.current.stop();
      managerRef.current = null;
      setAudioMonitorState('stopped');
    }
  }, [connected, setAudioMonitorState]);

  // Visibility change: stop when backgrounded, resume when foregrounded
  useEffect(() => {
    const handleVisibility = () => {
      if (document.visibilityState === 'hidden') {
        // Stop streaming to save bandwidth while backgrounded
        if (managerRef.current) {
          stopPipeline();
          setAudioMonitorState('stopped');
        }
      } else if (document.visibilityState === 'visible') {
        // Resume if user had requested monitoring
        if (audioMonitorRequested && isConnected()) {
          startPipeline();
        }
      }
    };

    document.addEventListener('visibilitychange', handleVisibility);
    return () => document.removeEventListener('visibilitychange', handleVisibility);
  }, [audioMonitorRequested, startPipeline, stopPipeline, setAudioMonitorState]);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      setBinaryHandler(null);
      if (managerRef.current) {
        managerRef.current.stop();
        managerRef.current = null;
      }
    };
  }, []);

  return {
    startMonitoring,
    stopMonitoring,
    isActive: audioMonitorState === 'buffering' || audioMonitorState === 'streaming',
    isRequested: audioMonitorRequested,
  };
}
