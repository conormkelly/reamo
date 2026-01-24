/**
 * SendFader Component
 * Gold/orange vertical fader for controlling send levels in Sends mode.
 * Shows "-∞" when no send exists or send is at minimum volume.
 */

import { useState, useCallback, useRef, useEffect, type ReactElement } from 'react';
import { useReaper } from '../ReaperProvider';
import { useTrack } from '../../hooks/useTrack';
import { useSends } from '../../hooks/useSends';
import { useReaperStore } from '../../store';
import { gesture, send } from '../../core/WebSocketCommands';
import { faderToVolume, volumeToFader, volumeToDb } from '../../utils/volume';

export interface SendFaderProps {
  /** Source track index */
  trackIndex: number;
  /** Destination track index (the send target) */
  destTrackIdx: number;
  className?: string;
  height?: number;
  /** Whether parent track is selected (affects background brightness) */
  isSelected?: boolean;
  /** Whether to show the dB label below the fader (default: true) */
  showDbLabel?: boolean;
}

export function SendFader({
  trackIndex,
  destTrackIdx,
  className = '',
  height = 150,
  isSelected = false,
  showDbLabel = true,
}: SendFaderProps): ReactElement {
  const { sendCommand } = useReaper();
  const { guid } = useTrack(trackIndex);
  const { getSendByDestination } = useSends();
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const [isDragging, setIsDragging] = useState(false);
  const [hasMounted, setHasMounted] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastTapRef = useRef<number>(0);
  const cleanupRef = useRef<(() => void) | null>(null);
  const gestureGuidRef = useRef<string | null>(null);
  const sendIndexRef = useRef<number>(0);

  // Get the send slot for this track/destination pair
  const sendSlot = getSendByDestination(trackIndex, destTrackIdx);
  const hasSend = !!sendSlot;
  const sendVolume = sendSlot?.volume ?? 0;
  const sendIndex = sendSlot?.sendIndex ?? 0;
  const isMuted = sendSlot?.muted ?? false;

  // Convert volume to fader position (0-1)
  const faderPosition = hasSend ? volumeToFader(sendVolume) : 0;

  // Format dB display
  const volumeDb = hasSend
    ? volumeToDb(sendVolume)
    : '-∞';

  // Enable transitions only after first render
  useEffect(() => {
    const timer = setTimeout(() => setHasMounted(true), 50);
    return () => clearTimeout(timer);
  }, []);

  // Cleanup event listeners on unmount
  useEffect(() => {
    return () => {
      if (cleanupRef.current) {
        cleanupRef.current();
      }
    };
  }, []);

  // Handle double-tap to reset to unity
  const handleDoubleTap = useCallback(() => {
    if (!hasSend) return;
    sendCommand(send.setVolume(trackIndex, sendIndex, 1.0));
  }, [sendCommand, trackIndex, sendIndex, hasSend]);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      // Ignore input when mixer is locked or no send exists
      if (mixerLocked || !hasSend) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastTapRef.current < 300) {
        e.preventDefault();
        lastTapRef.current = 0;
        handleDoubleTap();
        return;
      }
      lastTapRef.current = now;

      // REQUIRE GUID for gestures
      if (!guid) {
        console.warn(`SendFader: No GUID for track ${trackIndex}, gesture blocked`);
        return;
      }

      e.preventDefault();
      setIsDragging(true);

      // Lock GUID and send index at gesture start
      gestureGuidRef.current = guid;
      sendIndexRef.current = sendIndex;

      // Signal gesture start for undo coalescing
      sendCommand(gesture.start('send', trackIndex, gestureGuidRef.current, sendIndexRef.current));

      const getY = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientY;
        }
        return event.clientY;
      };

      const updatePosition = (clientY: number) => {
        if (!containerRef.current || !gestureGuidRef.current) return;
        const rect = containerRef.current.getBoundingClientRect();
        const y = clientY - rect.top;
        const position = 1 - Math.max(0, Math.min(1, y / rect.height));
        const linearVolume = faderToVolume(position);
        sendCommand(send.setVolume(trackIndex, sendIndexRef.current, linearVolume));
      };

      // Handle initial click position
      const initialY = 'touches' in e ? e.touches[0].clientY : e.clientY;
      updatePosition(initialY);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePosition(getY(event));
      };

      const handleUp = () => {
        setIsDragging(false);
        if (gestureGuidRef.current) {
          sendCommand(gesture.end('send', trackIndex, gestureGuidRef.current, sendIndexRef.current));
        }
        gestureGuidRef.current = null;
        document.removeEventListener('mousemove', handleMove);
        document.removeEventListener('mouseup', handleUp);
        document.removeEventListener('touchmove', handleMove);
        document.removeEventListener('touchend', handleUp);
        cleanupRef.current = null;
      };

      document.addEventListener('mousemove', handleMove);
      document.addEventListener('mouseup', handleUp);
      document.addEventListener('touchmove', handleMove, { passive: false });
      document.addEventListener('touchend', handleUp);

      cleanupRef.current = handleUp;
    },
    [sendCommand, handleDoubleTap, mixerLocked, trackIndex, guid, hasSend, sendIndex]
  );

  const handleHeight = Math.max(0, Math.min(height, faderPosition * height));

  // Determine cursor and opacity based on state
  const cursorClass = !hasSend
    ? 'cursor-default opacity-30'
    : mixerLocked
      ? 'cursor-not-allowed opacity-50'
      : 'cursor-ns-resize';

  return (
    <div className={`flex flex-col items-center gap-1 ${className}`}>
      <div
        ref={containerRef}
        className={`relative w-8 rounded touch-none ${
          isSelected ? 'bg-bg-disabled' : 'bg-bg-elevated'
        } ${cursorClass} ${isDragging ? 'ring-2 ring-sends-ring' : ''}`}
        style={{ height }}
        onMouseDown={handleMouseDown}
        onTouchStart={handleMouseDown}
        title={hasSend ? 'Send level - double-tap to reset to 0dB' : 'No send to this destination'}
      >
        {/* Fader track - gold/amber color for sends */}
        <div
          className={`absolute bottom-0 left-0 right-0 bg-sends-primary rounded-b ${hasMounted ? 'transition-all duration-75' : ''}`}
          style={{ height: handleHeight }}
        />
        {/* Fader handle - slightly amber tinted */}
        <div
          className={`absolute left-0 right-0 h-3 bg-sends-light rounded shadow-md ${hasMounted ? 'transition-all duration-75' : ''}`}
          style={{ bottom: Math.max(0, handleHeight - 6) }}
        />
      </div>
      {showDbLabel && (
        <span className={`text-[10px] font-mono whitespace-nowrap w-[52px] text-center ${isMuted ? 'text-sends-primary/50 line-through' : 'text-sends-primary'}`}>
          {volumeDb}
        </span>
      )}
    </div>
  );
}
