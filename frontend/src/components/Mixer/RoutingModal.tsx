/**
 * RoutingModal - View and control track sends/receives
 * Shows horizontal faders for each send/receive with tabs to switch between them.
 */

import { useState, useMemo, useCallback, useRef, useEffect, type ReactElement } from 'react';
import { Volume2, VolumeX } from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useTrack } from '../../hooks/useTrack';
import { useTrackSkeleton } from '../../hooks';
import { useReaperStore, getSendsFromTrack, getSendsToTrack } from '../../store';
import { useReaper } from '../ReaperProvider';
import { send as sendCmd, receive as receiveCmd, hw as hwCmd, gesture, routing as routingCmd } from '../../core/WebSocketCommands';
import { volumeToDbString, faderToVolume, volumeToFader } from '../../utils/volume';

export interface RoutingModalProps {
  /** Whether the modal is open */
  isOpen: boolean;
  /** Called when modal should close */
  onClose: () => void;
  /** Track index to show routing for */
  trackIndex: number;
}

type RoutingTab = 'sends' | 'receives' | 'hardware';

/**
 * Horizontal fader for send/receive volume control
 */
/** Mode display labels: 0=Post, 1=Pre-FX, 3=Post-FX */
const MODE_LABELS: Record<number, string> = {
  0: 'Post',
  1: 'Pre-FX',
  3: 'Post-FX',
};

/** Cycle mode: 0 → 1 → 3 → 0 */
function nextMode(mode: number): number {
  if (mode === 0) return 1;
  if (mode === 1) return 3;
  return 0;
}

function HorizontalSendFader({
  trackIndex,
  sendIndex,
  volume,
  pan,
  muted,
  mode,
  destName,
}: {
  trackIndex: number;
  sendIndex: number;
  volume: number;
  pan: number;
  muted: boolean;
  mode: number;
  destName: string;
}): ReactElement {
  const { sendCommand } = useReaper();
  const { guid } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const [isDragging, setIsDragging] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastTapRef = useRef<number>(0);
  const cleanupRef = useRef<(() => void) | null>(null);
  const gestureGuidRef = useRef<string | null>(null);
  const sendIndexRef = useRef<number>(sendIndex);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (cleanupRef.current) {
        cleanupRef.current();
      }
    };
  }, []);

  const faderPosition = volumeToFader(volume);
  const volumeDb = volumeToDbString(volume);

  // Handle double-tap to reset to unity
  const handleDoubleTap = useCallback(() => {
    sendCommand(sendCmd.setVolume(trackIndex, sendIndex, 1.0));
  }, [sendCommand, trackIndex, sendIndex]);

  // Toggle mute
  const handleToggleMute = useCallback(() => {
    sendCommand(sendCmd.setMute(trackIndex, sendIndex, muted ? 0 : 1));
  }, [sendCommand, trackIndex, sendIndex, muted]);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      if (mixerLocked) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastTapRef.current < 300) {
        e.preventDefault();
        lastTapRef.current = 0;
        handleDoubleTap();
        return;
      }
      lastTapRef.current = now;

      if (!guid) {
        console.warn(`HorizontalSendFader: No GUID for track ${trackIndex}, gesture blocked`);
        return;
      }

      e.preventDefault();
      setIsDragging(true);

      gestureGuidRef.current = guid;
      sendIndexRef.current = sendIndex;

      sendCommand(gesture.start('send', trackIndex, gestureGuidRef.current, sendIndexRef.current));

      const getX = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientX;
        }
        return event.clientX;
      };

      const updatePosition = (clientX: number) => {
        if (!containerRef.current || !gestureGuidRef.current) return;
        const rect = containerRef.current.getBoundingClientRect();
        const x = clientX - rect.left;
        const position = Math.max(0, Math.min(1, x / rect.width));
        const linearVolume = faderToVolume(position);
        sendCommand(sendCmd.setVolume(trackIndex, sendIndexRef.current, linearVolume));
      };

      const initialX = 'touches' in e ? e.touches[0].clientX : e.clientX;
      updatePosition(initialX);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePosition(getX(event));
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
    [sendCommand, handleDoubleTap, mixerLocked, trackIndex, sendIndex, guid]
  );

  const indicatorPosition = faderPosition * 100;

  // Pan slider state
  const [isPanDragging, setIsPanDragging] = useState(false);
  const panContainerRef = useRef<HTMLDivElement>(null);
  const lastPanTapRef = useRef<number>(0);
  const panCleanupRef = useRef<(() => void) | null>(null);
  const panGestureGuidRef = useRef<string | null>(null);

  // Format pan display
  const formatPan = (p: number): string => {
    if (Math.abs(p) < 0.01) return 'C';
    const pct = Math.round(Math.abs(p) * 100);
    return p < 0 ? `L${pct}` : `R${pct}`;
  };

  // Handle double-tap to center pan
  const handlePanDoubleTap = useCallback(() => {
    sendCommand(sendCmd.setPan(trackIndex, sendIndex, 0));
  }, [sendCommand, trackIndex, sendIndex]);

  // Handle mode toggle
  const handleModeToggle = useCallback(() => {
    sendCommand(sendCmd.setMode(trackIndex, sendIndex, nextMode(mode)));
  }, [sendCommand, trackIndex, sendIndex, mode]);

  // Pan slider mouse/touch handler
  const handlePanMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      if (mixerLocked) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastPanTapRef.current < 300) {
        e.preventDefault();
        lastPanTapRef.current = 0;
        handlePanDoubleTap();
        return;
      }
      lastPanTapRef.current = now;

      if (!guid) {
        console.warn(`HorizontalSendFader: No GUID for track ${trackIndex}, pan gesture blocked`);
        return;
      }

      e.preventDefault();
      setIsPanDragging(true);

      panGestureGuidRef.current = guid;
      sendIndexRef.current = sendIndex;

      sendCommand(gesture.start('sendPan', trackIndex, panGestureGuidRef.current, sendIndexRef.current));

      const getX = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientX;
        }
        return event.clientX;
      };

      const updatePan = (clientX: number) => {
        if (!panContainerRef.current || !panGestureGuidRef.current) return;
        const rect = panContainerRef.current.getBoundingClientRect();
        const x = clientX - rect.left;
        const position = Math.max(0, Math.min(1, x / rect.width));
        const newPan = position * 2 - 1; // Convert 0-1 to -1 to 1
        sendCommand(sendCmd.setPan(trackIndex, sendIndexRef.current, newPan));
      };

      const initialX = 'touches' in e ? e.touches[0].clientX : e.clientX;
      updatePan(initialX);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePan(getX(event));
      };

      const handleUp = () => {
        setIsPanDragging(false);
        if (panGestureGuidRef.current) {
          sendCommand(gesture.end('sendPan', trackIndex, panGestureGuidRef.current, sendIndexRef.current));
        }
        panGestureGuidRef.current = null;
        document.removeEventListener('mousemove', handleMove);
        document.removeEventListener('mouseup', handleUp);
        document.removeEventListener('touchmove', handleMove);
        document.removeEventListener('touchend', handleUp);
        panCleanupRef.current = null;
      };

      document.addEventListener('mousemove', handleMove);
      document.addEventListener('mouseup', handleUp);
      document.addEventListener('touchmove', handleMove, { passive: false });
      document.addEventListener('touchend', handleUp);

      panCleanupRef.current = handleUp;
    },
    [sendCommand, handlePanDoubleTap, mixerLocked, trackIndex, sendIndex, guid]
  );

  // Cleanup pan gesture on unmount
  useEffect(() => {
    return () => {
      if (panCleanupRef.current) {
        panCleanupRef.current();
      }
    };
  }, []);

  // Convert pan (-1 to 1) to percentage (0 to 100)
  const panPosition = ((pan + 1) / 2) * 100;

  return (
    <div className="py-2 space-y-2">
      {/* Row 1: Volume controls */}
      <div className="flex items-center gap-3">
        {/* Mute button */}
        <button
          onClick={handleToggleMute}
          className={`w-11 h-11 flex items-center justify-center rounded-lg transition-colors ${
            muted
              ? 'bg-sends-primary/20 text-sends-primary'
              : 'bg-bg-surface text-text-secondary hover:bg-bg-elevated'
          }`}
          title={muted ? 'Unmute send' : 'Mute send'}
        >
          {muted ? <VolumeX size={20} /> : <Volume2 size={20} />}
        </button>

        {/* Destination name */}
        <span className="text-sm text-text-primary w-24 truncate" title={destName}>
          {destName}
        </span>

        {/* Horizontal fader */}
        <div
          ref={containerRef}
          className={`relative flex-1 h-8 bg-bg-elevated rounded touch-none ${
            mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ew-resize'
          } ${isDragging ? 'ring-2 ring-sends-ring' : ''}`}
          onMouseDown={handleMouseDown}
          onTouchStart={handleMouseDown}
          title="Send level - double-tap to reset to 0dB"
        >
          {/* Fill */}
          <div
            className="absolute top-0 bottom-0 left-0 bg-sends-primary rounded-l transition-all duration-75"
            style={{ width: `${indicatorPosition}%` }}
          />
          {/* Handle */}
          <div
            className="absolute top-1 bottom-1 w-3 bg-sends-light rounded shadow-md transition-all duration-75"
            style={{ left: `calc(${indicatorPosition}% - 6px)` }}
          />
        </div>

        {/* dB readout */}
        <span className={`text-xs font-mono w-16 text-right ${muted ? 'text-sends-primary/50 line-through' : 'text-sends-primary'}`}>
          {volumeDb}
        </span>
      </div>

      {/* Row 2: Pan and Mode controls */}
      <div className="flex items-center gap-3 pl-14">
        {/* Pan slider */}
        <div
          ref={panContainerRef}
          className={`relative flex-1 h-6 bg-bg-elevated rounded touch-none ${
            mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ew-resize'
          } ${isPanDragging ? 'ring-2 ring-sends-ring' : ''}`}
          onMouseDown={handlePanMouseDown}
          onTouchStart={handlePanMouseDown}
          title="Send pan - double-tap to center"
        >
          {/* Center line */}
          <div className="absolute top-0 bottom-0 left-1/2 w-px bg-border-subtle" />
          {/* Handle */}
          <div
            className="absolute top-1 bottom-1 w-3 bg-sends-light rounded shadow-md transition-all duration-75"
            style={{ left: `calc(${panPosition}% - 6px)` }}
          />
        </div>

        {/* Pan readout */}
        <span className="text-xs font-mono w-10 text-center text-text-secondary">
          {formatPan(pan)}
        </span>

        {/* Mode badge */}
        <button
          onClick={handleModeToggle}
          disabled={mixerLocked}
          className={`px-2 py-1 text-xs rounded-md transition-colors ${
            mixerLocked
              ? 'bg-bg-surface text-text-muted cursor-not-allowed'
              : 'bg-bg-surface text-text-secondary hover:bg-bg-elevated'
          }`}
          title={`Mode: ${MODE_LABELS[mode] || 'Unknown'} - tap to cycle`}
        >
          {MODE_LABELS[mode] || '?'}
        </button>
      </div>
    </div>
  );
}

/**
 * Interactive row for receives - mirrors HorizontalSendFader but for receive controls
 */
function HorizontalReceiveFader({
  trackIndex,
  recvIdx,
  volume,
  pan,
  muted,
  mode,
  srcName,
}: {
  trackIndex: number;
  recvIdx: number;
  volume: number;
  pan: number;
  muted: boolean;
  mode: number;
  srcName: string;
}): ReactElement {
  const { sendCommand } = useReaper();
  const { guid } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const [isDragging, setIsDragging] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastTapRef = useRef<number>(0);
  const cleanupRef = useRef<(() => void) | null>(null);
  const gestureGuidRef = useRef<string | null>(null);
  const recvIdxRef = useRef<number>(recvIdx);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (cleanupRef.current) {
        cleanupRef.current();
      }
    };
  }, []);

  const faderPosition = volumeToFader(volume);
  const volumeDb = volumeToDbString(volume);

  // Handle double-tap to reset to unity
  const handleDoubleTap = useCallback(() => {
    sendCommand(receiveCmd.setVolume(trackIndex, recvIdx, 1.0));
  }, [sendCommand, trackIndex, recvIdx]);

  // Toggle mute
  const handleToggleMute = useCallback(() => {
    sendCommand(receiveCmd.setMute(trackIndex, recvIdx, muted ? 0 : 1));
  }, [sendCommand, trackIndex, recvIdx, muted]);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      if (mixerLocked) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastTapRef.current < 300) {
        e.preventDefault();
        lastTapRef.current = 0;
        handleDoubleTap();
        return;
      }
      lastTapRef.current = now;

      if (!guid) {
        console.warn(`HorizontalReceiveFader: No GUID for track ${trackIndex}, gesture blocked`);
        return;
      }

      e.preventDefault();
      setIsDragging(true);

      gestureGuidRef.current = guid;
      recvIdxRef.current = recvIdx;

      sendCommand(gesture.start('receive', trackIndex, gestureGuidRef.current, undefined, undefined, recvIdxRef.current));

      const getX = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientX;
        }
        return event.clientX;
      };

      const updatePosition = (clientX: number) => {
        if (!containerRef.current || !gestureGuidRef.current) return;
        const rect = containerRef.current.getBoundingClientRect();
        const x = clientX - rect.left;
        const position = Math.max(0, Math.min(1, x / rect.width));
        const linearVolume = faderToVolume(position);
        sendCommand(receiveCmd.setVolume(trackIndex, recvIdxRef.current, linearVolume));
      };

      const initialX = 'touches' in e ? e.touches[0].clientX : e.clientX;
      updatePosition(initialX);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePosition(getX(event));
      };

      const handleUp = () => {
        setIsDragging(false);
        if (gestureGuidRef.current) {
          sendCommand(gesture.end('receive', trackIndex, gestureGuidRef.current, undefined, undefined, recvIdxRef.current));
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
    [sendCommand, handleDoubleTap, mixerLocked, trackIndex, recvIdx, guid]
  );

  const indicatorPosition = faderPosition * 100;

  // Pan slider state
  const [isPanDragging, setIsPanDragging] = useState(false);
  const panContainerRef = useRef<HTMLDivElement>(null);
  const lastPanTapRef = useRef<number>(0);
  const panCleanupRef = useRef<(() => void) | null>(null);
  const panGestureGuidRef = useRef<string | null>(null);

  // Format pan display
  const formatPan = (p: number): string => {
    if (Math.abs(p) < 0.01) return 'C';
    const pct = Math.round(Math.abs(p) * 100);
    return p < 0 ? `L${pct}` : `R${pct}`;
  };

  // Handle double-tap to center pan
  const handlePanDoubleTap = useCallback(() => {
    sendCommand(receiveCmd.setPan(trackIndex, recvIdx, 0));
  }, [sendCommand, trackIndex, recvIdx]);

  // Handle mode toggle
  const handleModeToggle = useCallback(() => {
    sendCommand(receiveCmd.setMode(trackIndex, recvIdx, nextMode(mode)));
  }, [sendCommand, trackIndex, recvIdx, mode]);

  // Pan slider mouse/touch handler
  const handlePanMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      if (mixerLocked) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastPanTapRef.current < 300) {
        e.preventDefault();
        lastPanTapRef.current = 0;
        handlePanDoubleTap();
        return;
      }
      lastPanTapRef.current = now;

      if (!guid) {
        console.warn(`HorizontalReceiveFader: No GUID for track ${trackIndex}, pan gesture blocked`);
        return;
      }

      e.preventDefault();
      setIsPanDragging(true);

      panGestureGuidRef.current = guid;
      recvIdxRef.current = recvIdx;

      sendCommand(gesture.start('receivePan', trackIndex, panGestureGuidRef.current, undefined, undefined, recvIdxRef.current));

      const getX = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientX;
        }
        return event.clientX;
      };

      const updatePan = (clientX: number) => {
        if (!panContainerRef.current || !panGestureGuidRef.current) return;
        const rect = panContainerRef.current.getBoundingClientRect();
        const x = clientX - rect.left;
        const position = Math.max(0, Math.min(1, x / rect.width));
        const newPan = position * 2 - 1; // Convert 0-1 to -1 to 1
        sendCommand(receiveCmd.setPan(trackIndex, recvIdxRef.current, newPan));
      };

      const initialX = 'touches' in e ? e.touches[0].clientX : e.clientX;
      updatePan(initialX);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePan(getX(event));
      };

      const handleUp = () => {
        setIsPanDragging(false);
        if (panGestureGuidRef.current) {
          sendCommand(gesture.end('receivePan', trackIndex, panGestureGuidRef.current, undefined, undefined, recvIdxRef.current));
        }
        panGestureGuidRef.current = null;
        document.removeEventListener('mousemove', handleMove);
        document.removeEventListener('mouseup', handleUp);
        document.removeEventListener('touchmove', handleMove);
        document.removeEventListener('touchend', handleUp);
        panCleanupRef.current = null;
      };

      document.addEventListener('mousemove', handleMove);
      document.addEventListener('mouseup', handleUp);
      document.addEventListener('touchmove', handleMove, { passive: false });
      document.addEventListener('touchend', handleUp);

      panCleanupRef.current = handleUp;
    },
    [sendCommand, handlePanDoubleTap, mixerLocked, trackIndex, recvIdx, guid]
  );

  // Cleanup pan gesture on unmount
  useEffect(() => {
    return () => {
      if (panCleanupRef.current) {
        panCleanupRef.current();
      }
    };
  }, []);

  // Convert pan (-1 to 1) to percentage (0 to 100)
  const panPosition = ((pan + 1) / 2) * 100;

  return (
    <div className="py-2 space-y-2">
      {/* Row 1: Volume controls */}
      <div className="flex items-center gap-3">
        {/* Mute button */}
        <button
          onClick={handleToggleMute}
          className={`w-11 h-11 flex items-center justify-center rounded-lg transition-colors ${
            muted
              ? 'bg-blue-500/20 text-blue-400'
              : 'bg-bg-surface text-text-secondary hover:bg-bg-elevated'
          }`}
          title={muted ? 'Unmute receive' : 'Mute receive'}
        >
          {muted ? <VolumeX size={20} /> : <Volume2 size={20} />}
        </button>

        {/* Source name */}
        <span className="text-sm text-text-primary w-24 truncate" title={srcName}>
          {srcName}
        </span>

        {/* Horizontal fader */}
        <div
          ref={containerRef}
          className={`relative flex-1 h-8 bg-bg-elevated rounded touch-none ${
            mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ew-resize'
          } ${isDragging ? 'ring-2 ring-blue-400' : ''}`}
          onMouseDown={handleMouseDown}
          onTouchStart={handleMouseDown}
          title="Receive level - double-tap to reset to 0dB"
        >
          {/* Fill */}
          <div
            className="absolute top-0 bottom-0 left-0 bg-blue-500/50 rounded-l transition-all duration-75"
            style={{ width: `${indicatorPosition}%` }}
          />
          {/* Handle */}
          <div
            className="absolute top-1 bottom-1 w-3 bg-blue-200 rounded shadow-md transition-all duration-75"
            style={{ left: `calc(${indicatorPosition}% - 6px)` }}
          />
        </div>

        {/* dB readout */}
        <span className={`text-xs font-mono w-16 text-right ${muted ? 'text-blue-400/50 line-through' : 'text-blue-400'}`}>
          {volumeDb}
        </span>
      </div>

      {/* Row 2: Pan and Mode controls */}
      <div className="flex items-center gap-3 pl-14">
        {/* Pan slider */}
        <div
          ref={panContainerRef}
          className={`relative flex-1 h-6 bg-bg-elevated rounded touch-none ${
            mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ew-resize'
          } ${isPanDragging ? 'ring-2 ring-blue-400' : ''}`}
          onMouseDown={handlePanMouseDown}
          onTouchStart={handlePanMouseDown}
          title="Receive pan - double-tap to center"
        >
          {/* Center line */}
          <div className="absolute top-0 bottom-0 left-1/2 w-px bg-border-subtle" />
          {/* Handle */}
          <div
            className="absolute top-1 bottom-1 w-3 bg-blue-200 rounded shadow-md transition-all duration-75"
            style={{ left: `calc(${panPosition}% - 6px)` }}
          />
        </div>

        {/* Pan readout */}
        <span className="text-xs font-mono w-10 text-center text-text-secondary">
          {formatPan(pan)}
        </span>

        {/* Mode badge */}
        <button
          onClick={handleModeToggle}
          disabled={mixerLocked}
          className={`px-2 py-1 text-xs rounded-md transition-colors ${
            mixerLocked
              ? 'bg-bg-surface text-text-muted cursor-not-allowed'
              : 'bg-bg-surface text-text-secondary hover:bg-bg-elevated'
          }`}
          title={`Mode: ${MODE_LABELS[mode] || 'Unknown'} - tap to cycle`}
        >
          {MODE_LABELS[mode] || '?'}
        </button>
      </div>
    </div>
  );
}

/**
 * Generate display name from destChannel encoding
 * Lower 10 bits = channel index, upper bits = number of channels
 */
function formatHwOutputName(destChannel: number): string {
  const channelIdx = destChannel & 0x3FF;
  const numChans = (destChannel >> 10) & 0x3FF;
  const startCh = channelIdx + 1;
  // Mono if numChans is 0 or 1
  if (numChans <= 1) {
    return `HW Out ${startCh}`;
  }
  return `HW Out ${startCh}/${startCh + numChans - 1}`;
}

/**
 * Hardware output row with volume, pan, mute, and mode controls
 */
function HwOutputRow({
  trackIndex,
  hwIdx,
  destChannel,
  volume,
  pan,
  muted,
  mode,
}: {
  trackIndex: number;
  hwIdx: number;
  destChannel: number;
  volume: number;
  pan: number;
  muted: boolean;
  mode: number;
}): ReactElement {
  const { sendCommand } = useReaper();
  const { guid } = useTrack(trackIndex);
  const mixerLocked = useReaperStore((s) => s.mixerLocked);
  const [isDragging, setIsDragging] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const lastTapRef = useRef<number>(0);
  const cleanupRef = useRef<(() => void) | null>(null);
  const gestureGuidRef = useRef<string | null>(null);
  const hwIdxRef = useRef<number>(hwIdx);

  // Cleanup on unmount
  useEffect(() => {
    return () => {
      if (cleanupRef.current) {
        cleanupRef.current();
      }
    };
  }, []);

  const faderPosition = volumeToFader(volume);
  const volumeDb = volumeToDbString(volume);
  const displayName = formatHwOutputName(destChannel);

  // Handle double-tap to reset to unity
  const handleDoubleTap = useCallback(() => {
    sendCommand(hwCmd.setVolume(trackIndex, hwIdx, 1.0));
  }, [sendCommand, trackIndex, hwIdx]);

  // Toggle mute
  const handleToggleMute = useCallback(() => {
    sendCommand(hwCmd.setMute(trackIndex, hwIdx, muted ? 0 : 1));
  }, [sendCommand, trackIndex, hwIdx, muted]);

  const handleMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      if (mixerLocked) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastTapRef.current < 300) {
        e.preventDefault();
        lastTapRef.current = 0;
        handleDoubleTap();
        return;
      }
      lastTapRef.current = now;

      if (!guid) {
        console.warn(`HwOutputRow: No GUID for track ${trackIndex}, gesture blocked`);
        return;
      }

      e.preventDefault();
      setIsDragging(true);

      gestureGuidRef.current = guid;
      hwIdxRef.current = hwIdx;

      sendCommand(gesture.start('hwOutputVolume', trackIndex, gestureGuidRef.current, undefined, hwIdxRef.current));

      const getX = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientX;
        }
        return event.clientX;
      };

      const updatePosition = (clientX: number) => {
        if (!containerRef.current || !gestureGuidRef.current) return;
        const rect = containerRef.current.getBoundingClientRect();
        const x = clientX - rect.left;
        const position = Math.max(0, Math.min(1, x / rect.width));
        const linearVolume = faderToVolume(position);
        sendCommand(hwCmd.setVolume(trackIndex, hwIdxRef.current, linearVolume));
      };

      const initialX = 'touches' in e ? e.touches[0].clientX : e.clientX;
      updatePosition(initialX);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePosition(getX(event));
      };

      const handleUp = () => {
        setIsDragging(false);
        if (gestureGuidRef.current) {
          sendCommand(gesture.end('hwOutputVolume', trackIndex, gestureGuidRef.current, undefined, hwIdxRef.current));
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
    [sendCommand, handleDoubleTap, mixerLocked, trackIndex, hwIdx, guid]
  );

  const indicatorPosition = faderPosition * 100;

  // Pan slider state
  const [isPanDragging, setIsPanDragging] = useState(false);
  const panContainerRef = useRef<HTMLDivElement>(null);
  const lastPanTapRef = useRef<number>(0);
  const panCleanupRef = useRef<(() => void) | null>(null);
  const panGestureGuidRef = useRef<string | null>(null);

  // Format pan display
  const formatPan = (p: number): string => {
    if (Math.abs(p) < 0.01) return 'C';
    const pct = Math.round(Math.abs(p) * 100);
    return p < 0 ? `L${pct}` : `R${pct}`;
  };

  // Handle double-tap to center pan
  const handlePanDoubleTap = useCallback(() => {
    sendCommand(hwCmd.setPan(trackIndex, hwIdx, 0));
  }, [sendCommand, trackIndex, hwIdx]);

  // Handle mode toggle
  const handleModeToggle = useCallback(() => {
    sendCommand(hwCmd.setMode(trackIndex, hwIdx, nextMode(mode)));
  }, [sendCommand, trackIndex, hwIdx, mode]);

  // Pan slider mouse/touch handler
  const handlePanMouseDown = useCallback(
    (e: React.MouseEvent | React.TouchEvent) => {
      if (mixerLocked) return;

      // Check for double-tap
      const now = Date.now();
      if (now - lastPanTapRef.current < 300) {
        e.preventDefault();
        lastPanTapRef.current = 0;
        handlePanDoubleTap();
        return;
      }
      lastPanTapRef.current = now;

      if (!guid) {
        console.warn(`HwOutputRow: No GUID for track ${trackIndex}, pan gesture blocked`);
        return;
      }

      e.preventDefault();
      setIsPanDragging(true);

      panGestureGuidRef.current = guid;
      hwIdxRef.current = hwIdx;

      sendCommand(gesture.start('hwOutputPan', trackIndex, panGestureGuidRef.current, undefined, hwIdxRef.current));

      const getX = (event: MouseEvent | TouchEvent): number => {
        if ('touches' in event) {
          return event.touches[0].clientX;
        }
        return event.clientX;
      };

      const updatePan = (clientX: number) => {
        if (!panContainerRef.current || !panGestureGuidRef.current) return;
        const rect = panContainerRef.current.getBoundingClientRect();
        const x = clientX - rect.left;
        const position = Math.max(0, Math.min(1, x / rect.width));
        const newPan = position * 2 - 1; // Convert 0-1 to -1 to 1
        sendCommand(hwCmd.setPan(trackIndex, hwIdxRef.current, newPan));
      };

      const initialX = 'touches' in e ? e.touches[0].clientX : e.clientX;
      updatePan(initialX);

      const handleMove = (event: MouseEvent | TouchEvent) => {
        event.preventDefault();
        updatePan(getX(event));
      };

      const handleUp = () => {
        setIsPanDragging(false);
        if (panGestureGuidRef.current) {
          sendCommand(gesture.end('hwOutputPan', trackIndex, panGestureGuidRef.current, undefined, hwIdxRef.current));
        }
        panGestureGuidRef.current = null;
        document.removeEventListener('mousemove', handleMove);
        document.removeEventListener('mouseup', handleUp);
        document.removeEventListener('touchmove', handleMove);
        document.removeEventListener('touchend', handleUp);
        panCleanupRef.current = null;
      };

      document.addEventListener('mousemove', handleMove);
      document.addEventListener('mouseup', handleUp);
      document.addEventListener('touchmove', handleMove, { passive: false });
      document.addEventListener('touchend', handleUp);

      panCleanupRef.current = handleUp;
    },
    [sendCommand, handlePanDoubleTap, mixerLocked, trackIndex, hwIdx, guid]
  );

  // Cleanup pan gesture on unmount
  useEffect(() => {
    return () => {
      if (panCleanupRef.current) {
        panCleanupRef.current();
      }
    };
  }, []);

  // Convert pan (-1 to 1) to percentage (0 to 100)
  const panPosition = ((pan + 1) / 2) * 100;

  return (
    <div className="py-2 space-y-2">
      {/* Row 1: Volume controls */}
      <div className="flex items-center gap-3">
        {/* Mute button */}
        <button
          onClick={handleToggleMute}
          className={`w-11 h-11 flex items-center justify-center rounded-lg transition-colors ${
            muted
              ? 'bg-purple-500/20 text-purple-400'
              : 'bg-bg-surface text-text-secondary hover:bg-bg-elevated'
          }`}
          title={muted ? 'Unmute hw output' : 'Mute hw output'}
        >
          {muted ? <VolumeX size={20} /> : <Volume2 size={20} />}
        </button>

        {/* Destination name */}
        <span className="text-sm text-text-primary w-24 truncate" title={displayName}>
          {displayName}
        </span>

        {/* Horizontal fader */}
        <div
          ref={containerRef}
          className={`relative flex-1 h-8 bg-bg-elevated rounded touch-none ${
            mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ew-resize'
          } ${isDragging ? 'ring-2 ring-purple-500/50' : ''}`}
          onMouseDown={handleMouseDown}
          onTouchStart={handleMouseDown}
          title="HW output level - double-tap to reset to 0dB"
        >
          {/* Fill */}
          <div
            className="absolute top-0 bottom-0 left-0 bg-purple-500 rounded-l transition-all duration-75"
            style={{ width: `${indicatorPosition}%` }}
          />
          {/* Handle */}
          <div
            className="absolute top-1 bottom-1 w-3 bg-purple-300 rounded shadow-md transition-all duration-75"
            style={{ left: `calc(${indicatorPosition}% - 6px)` }}
          />
        </div>

        {/* dB readout */}
        <span className={`text-xs font-mono w-16 text-right ${muted ? 'text-purple-400/50 line-through' : 'text-purple-400'}`}>
          {volumeDb}
        </span>
      </div>

      {/* Row 2: Pan and Mode controls */}
      <div className="flex items-center gap-3 pl-14">
        {/* Pan slider */}
        <div
          ref={panContainerRef}
          className={`relative flex-1 h-6 bg-bg-elevated rounded touch-none ${
            mixerLocked ? 'cursor-not-allowed opacity-50' : 'cursor-ew-resize'
          } ${isPanDragging ? 'ring-2 ring-purple-500/50' : ''}`}
          onMouseDown={handlePanMouseDown}
          onTouchStart={handlePanMouseDown}
          title="HW output pan - double-tap to center"
        >
          {/* Center line */}
          <div className="absolute top-0 bottom-0 left-1/2 w-px bg-border-subtle" />
          {/* Handle */}
          <div
            className="absolute top-1 bottom-1 w-3 bg-purple-300 rounded shadow-md transition-all duration-75"
            style={{ left: `calc(${panPosition}% - 6px)` }}
          />
        </div>

        {/* Pan readout */}
        <span className="text-xs font-mono w-10 text-center text-text-secondary">
          {formatPan(pan)}
        </span>

        {/* Mode badge */}
        <button
          onClick={handleModeToggle}
          disabled={mixerLocked}
          className={`px-2 py-1 text-xs rounded-md transition-colors ${
            mixerLocked
              ? 'bg-bg-surface text-text-muted cursor-not-allowed'
              : 'bg-bg-surface text-text-secondary hover:bg-bg-elevated'
          }`}
          title={`Mode: ${MODE_LABELS[mode] || 'Unknown'} - tap to cycle`}
        >
          {MODE_LABELS[mode] || '?'}
        </button>
      </div>
    </div>
  );
}

export function RoutingModal({
  isOpen,
  onClose,
  trackIndex,
}: RoutingModalProps): ReactElement {
  const { name: trackName, track, guid } = useTrack(trackIndex);
  const hwOutCount = track?.hwOutCount ?? 0;
  const { skeleton } = useTrackSkeleton();
  const sends = useReaperStore((s) => s.sends);
  const { sendCommand } = useReaper();

  // Routing subscription state from store
  const routingSends = useReaperStore((s) => s.routingSends);
  const routingReceives = useReaperStore((s) => s.routingReceives);
  const routingHwOutputs = useReaperStore((s) => s.routingHwOutputs);
  const setRoutingSubscription = useReaperStore((s) => s.setRoutingSubscription);
  const clearRoutingSubscription = useReaperStore((s) => s.clearRoutingSubscription);

  const [activeTab, setActiveTab] = useState<RoutingTab>('sends');

  // Subscribe to routing updates when modal opens, unsubscribe on close
  useEffect(() => {
    if (isOpen && guid) {
      // Set subscription state and send subscribe command
      setRoutingSubscription(guid);
      sendCommand(routingCmd.subscribe(guid));

      return () => {
        // Unsubscribe on close
        sendCommand(routingCmd.unsubscribe());
        clearRoutingSubscription();
      };
    }
  }, [isOpen, guid, sendCommand, setRoutingSubscription, clearRoutingSubscription]);

  // Use routing subscription data for sends (real-time updates during drag)
  const trackSends = useMemo(() => {
    // If we have routing subscription data, use it (includes pan)
    if (routingSends.length > 0) {
      return routingSends.map((s) => ({
        srcTrackIdx: trackIndex,
        destTrackIdx: -1, // Not available in routing subscription
        sendIndex: s.sendIndex,
        volume: s.volume,
        pan: s.pan,
        muted: s.muted,
        mode: s.mode,
        destName: s.destName,
      }));
    }
    // Fall back to global sends state (for initial render before subscription kicks in)
    // Map to include destName from skeleton lookup
    return getSendsFromTrack(sends, trackIndex).map((s) => ({
      ...s,
      destName: '', // Will be filled in from trackNameLookup at render time
    }));
  }, [routingSends, sends, trackIndex]);

  // Use routing subscription data for receives (real-time updates during drag)
  const trackReceives = useMemo(() => {
    // If we have routing subscription data, use it (includes pan)
    if (routingReceives.length > 0) {
      return routingReceives.map((r) => ({
        srcTrackIdx: -1, // Not available in routing subscription
        destTrackIdx: trackIndex,
        sendIndex: r.receiveIndex,
        volume: r.volume,
        pan: r.pan,
        muted: r.muted,
        mode: r.mode,
        srcName: r.srcName,
      }));
    }
    // Fall back to global sends state (for initial render before subscription kicks in)
    return getSendsToTrack(sends, trackIndex).map((s) => ({
      ...s,
      srcName: '', // Will be filled in from trackNameLookup at render time
    }));
  }, [routingReceives, sends, trackIndex]);

  // Use routing subscription data for hw outputs (real-time updates during drag)
  const hwOutputs = routingHwOutputs;

  // Build name lookup from skeleton
  const trackNameLookup = useMemo(() => {
    const lookup: Record<number, string> = {};
    skeleton.forEach((t, idx) => {
      lookup[idx] = t.n || `Track ${idx}`;
    });
    return lookup;
  }, [skeleton]);

  const hasSends = trackSends.length > 0 || (track?.sendCount ?? 0) > 0;
  const hasReceives = trackReceives.length > 0;
  const hasHwOutputs = hwOutCount > 0;

  // Auto-switch to receives tab if no sends but has receives
  useEffect(() => {
    if (isOpen && !hasSends && hasReceives) {
      setActiveTab('receives');
    } else if (isOpen && hasSends) {
      setActiveTab('sends');
    }
  }, [isOpen, hasSends, hasReceives]);

  const isMaster = trackIndex === 0;
  const displayName = trackName || (isMaster ? 'MASTER' : `Track ${trackIndex}`);

  return (
    <BottomSheet
      isOpen={isOpen}
      onClose={onClose}
      ariaLabel={`Routing for ${displayName}`}
    >
      <div className="px-4 pb-6">
        {/* Header */}
        <div className="text-center mb-3 pt-1">
          <h2 className="text-lg font-semibold text-text-primary truncate">
            Routing: {displayName}
          </h2>
        </div>

        {/* Tab selector */}
        <div className="flex gap-2 mb-4">
          <button
            onClick={() => setActiveTab('sends')}
            disabled={!hasSends}
            className={`flex-1 py-2 px-4 rounded-lg text-sm font-medium transition-colors ${
              activeTab === 'sends'
                ? 'bg-sends-primary/20 text-sends-primary border border-sends-border'
                : hasSends
                  ? 'bg-bg-surface text-text-secondary hover:bg-bg-elevated border border-border-subtle'
                  : 'bg-bg-surface/50 text-text-muted border border-border-subtle cursor-not-allowed'
            }`}
          >
            Sends ({trackSends.length})
          </button>
          <button
            onClick={() => setActiveTab('receives')}
            disabled={!hasReceives}
            className={`flex-1 py-2 px-4 rounded-lg text-sm font-medium transition-colors ${
              activeTab === 'receives'
                ? 'bg-blue-500/20 text-blue-500 border border-blue-500/50'
                : hasReceives
                  ? 'bg-bg-surface text-text-secondary hover:bg-bg-elevated border border-border-subtle'
                  : 'bg-bg-surface/50 text-text-muted border border-border-subtle cursor-not-allowed'
            }`}
          >
            Receives ({trackReceives.length})
          </button>
          <button
            onClick={() => setActiveTab('hardware')}
            disabled={!hasHwOutputs}
            className={`flex-1 py-2 px-4 rounded-lg text-sm font-medium transition-colors ${
              activeTab === 'hardware'
                ? 'bg-purple-500/20 text-purple-400 border border-purple-500/50'
                : hasHwOutputs
                  ? 'bg-bg-surface text-text-secondary hover:bg-bg-elevated border border-border-subtle'
                  : 'bg-bg-surface/50 text-text-muted border border-border-subtle cursor-not-allowed'
            }`}
          >
            Hardware ({hwOutCount})
          </button>
        </div>

        {/* Scrollable content */}
        <div className="max-h-80 overflow-y-auto -mx-4 px-4">
          <div className="space-y-1">
            {activeTab === 'sends' && (
              <>
                {trackSends.length === 0 ? (
                  <div className="text-center text-text-muted py-8">
                    <p>No sends from this track</p>
                    <p className="text-xs mt-1">Add sends in REAPER's routing window</p>
                  </div>
                ) : (
                  trackSends.map((s) => (
                    <HorizontalSendFader
                      key={`${s.srcTrackIdx}-${s.sendIndex}`}
                      trackIndex={s.srcTrackIdx}
                      sendIndex={s.sendIndex}
                      volume={s.volume}
                      pan={s.pan}
                      muted={s.muted}
                      mode={s.mode}
                      destName={s.destName || trackNameLookup[s.destTrackIdx] || `Track ${s.destTrackIdx}`}
                    />
                  ))
                )}
              </>
            )}

            {activeTab === 'receives' && (
              <>
                {trackReceives.length === 0 ? (
                  <div className="text-center text-text-muted py-8">
                    <p>No receives to this track</p>
                    <p className="text-xs mt-1">Other tracks send to this track via routing</p>
                  </div>
                ) : (
                  trackReceives.map((r) => (
                    <HorizontalReceiveFader
                      key={`recv-${r.sendIndex}`}
                      trackIndex={trackIndex}
                      recvIdx={r.sendIndex}
                      volume={r.volume}
                      pan={r.pan ?? 0}
                      muted={r.muted}
                      mode={r.mode ?? 0}
                      srcName={r.srcName || trackNameLookup[r.srcTrackIdx] || `Track ${r.srcTrackIdx}`}
                    />
                  ))
                )}
              </>
            )}

            {activeTab === 'hardware' && (
              <>
                {hwOutCount > 0 && hwOutputs.length === 0 ? (
                  <div className="text-center text-text-muted py-8">
                    <p>Loading hardware outputs...</p>
                  </div>
                ) : hwOutputs.length === 0 ? (
                  <div className="text-center text-text-muted py-8">
                    <p>No hardware outputs on this track</p>
                    <p className="text-xs mt-1">Add hardware outputs in REAPER's routing window</p>
                  </div>
                ) : (
                  hwOutputs.map((hw) => (
                    <HwOutputRow
                      key={hw.hwIdx}
                      trackIndex={trackIndex}
                      hwIdx={hw.hwIdx}
                      destChannel={hw.destChannel}
                      volume={hw.volume}
                      pan={hw.pan}
                      muted={hw.muted}
                      mode={hw.mode}
                    />
                  ))
                )}
              </>
            )}
          </div>
        </div>

        {/* Help text */}
        {!hasSends && !hasReceives && !hasHwOutputs && (
          <div className="text-center text-text-muted py-4 border-t border-border-subtle mt-4">
            <p className="text-sm">This track has no routing connections</p>
          </div>
        )}

        {/* Footer summary */}
        {(hasSends || hasReceives || hasHwOutputs) && (
          <div className="text-xs text-text-muted text-center mt-3 pt-3 border-t border-border-subtle">
            {trackSends.length} send{trackSends.length !== 1 ? 's' : ''} · {trackReceives.length} receive{trackReceives.length !== 1 ? 's' : ''} · {hwOutCount} hw out{hwOutCount !== 1 ? 's' : ''}
          </div>
        )}
      </div>
    </BottomSheet>
  );
}
