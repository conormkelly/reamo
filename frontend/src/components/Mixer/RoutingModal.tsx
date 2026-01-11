/**
 * RoutingModal - View and control track sends/receives
 * Shows horizontal faders for each send/receive with tabs to switch between them.
 */

import { useState, useMemo, useCallback, useRef, useEffect, type ReactElement } from 'react';
import { ArrowRightLeft, Volume2, VolumeX } from 'lucide-react';
import { Modal, ModalContent } from '../Modal';
import { useTrack } from '../../hooks/useTrack';
import { useTrackSkeleton } from '../../hooks';
import { useReaperStore, getSendsFromTrack, getSendsToTrack } from '../../store';
import { useReaper } from '../ReaperProvider';
import { send as sendCmd, gesture } from '../../core/WebSocketCommands';
import { volumeToDb, faderToVolume, volumeToFader } from '../../utils/volume';

export interface RoutingModalProps {
  /** Whether the modal is open */
  isOpen: boolean;
  /** Called when modal should close */
  onClose: () => void;
  /** Track index to show routing for */
  trackIndex: number;
}

type RoutingTab = 'sends' | 'receives';

/**
 * Horizontal fader for send/receive volume control
 */
function HorizontalSendFader({
  trackIndex,
  sendIndex,
  volume,
  muted,
  destName,
}: {
  trackIndex: number;
  sendIndex: number;
  volume: number;
  muted: boolean;
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
  const volumeDb = volumeToDb(volume);

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

  return (
    <div className="flex items-center gap-3 py-2">
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
  );
}

/**
 * Display-only row for receives (we can't control receive volume from the receiving end)
 */
function ReceiveRow({
  srcName,
  volume,
  muted,
}: {
  srcName: string;
  volume: number;
  muted: boolean;
}): ReactElement {
  const faderPosition = volumeToFader(volume);
  const volumeDb = volumeToDb(volume);
  const indicatorPosition = faderPosition * 100;

  return (
    <div className="flex items-center gap-3 py-2 opacity-75">
      {/* Mute indicator (read-only) */}
      <div
        className={`w-11 h-11 flex items-center justify-center rounded-lg ${
          muted ? 'bg-sends-primary/20 text-sends-primary' : 'bg-bg-surface text-text-muted'
        }`}
        title={muted ? 'Send is muted' : 'Send is active'}
      >
        {muted ? <VolumeX size={20} /> : <Volume2 size={20} />}
      </div>

      {/* Source name */}
      <span className="text-sm text-text-primary w-24 truncate" title={srcName}>
        {srcName}
      </span>

      {/* Level indicator (read-only) */}
      <div className="relative flex-1 h-8 bg-bg-elevated rounded cursor-default">
        {/* Fill */}
        <div
          className="absolute top-0 bottom-0 left-0 bg-blue-500/50 rounded-l"
          style={{ width: `${indicatorPosition}%` }}
        />
        {/* Handle */}
        <div
          className="absolute top-1 bottom-1 w-3 bg-blue-200 rounded shadow-md"
          style={{ left: `calc(${indicatorPosition}% - 6px)` }}
        />
      </div>

      {/* dB readout */}
      <span className={`text-xs font-mono w-16 text-right ${muted ? 'text-blue-500/50 line-through' : 'text-blue-500'}`}>
        {volumeDb}
      </span>
    </div>
  );
}

export function RoutingModal({
  isOpen,
  onClose,
  trackIndex,
}: RoutingModalProps): ReactElement {
  const { name: trackName } = useTrack(trackIndex);
  const { skeleton } = useTrackSkeleton();
  const sends = useReaperStore((s) => s.sends);

  const [activeTab, setActiveTab] = useState<RoutingTab>('sends');

  // Get sends from this track
  const trackSends = useMemo(
    () => getSendsFromTrack(sends, trackIndex),
    [sends, trackIndex]
  );

  // Get receives to this track (sends that have this track as destination)
  const trackReceives = useMemo(
    () => getSendsToTrack(sends, trackIndex),
    [sends, trackIndex]
  );

  // Build name lookup from skeleton
  const trackNameLookup = useMemo(() => {
    const lookup: Record<number, string> = {};
    skeleton.forEach((t, idx) => {
      lookup[idx] = t.n || `Track ${idx}`;
    });
    return lookup;
  }, [skeleton]);

  const hasSends = trackSends.length > 0;
  const hasReceives = trackReceives.length > 0;

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
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={`Routing: ${displayName}`}
      icon={<ArrowRightLeft size={18} className="text-text-secondary" />}
      width="lg"
    >
      <ModalContent>
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
        </div>

        {/* Content */}
        <div className="space-y-1 max-h-80 overflow-y-auto">
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
                    muted={s.muted}
                    destName={trackNameLookup[s.destTrackIdx] || `Track ${s.destTrackIdx}`}
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
                  <ReceiveRow
                    key={`${r.srcTrackIdx}-${r.sendIndex}`}
                    srcName={trackNameLookup[r.srcTrackIdx] || `Track ${r.srcTrackIdx}`}
                    volume={r.volume}
                    muted={r.muted}
                  />
                ))
              )}
            </>
          )}
        </div>

        {/* Help text */}
        {!hasSends && !hasReceives && (
          <div className="text-center text-text-muted py-4 border-t border-border-subtle mt-4">
            <p className="text-sm">This track has no routing connections</p>
          </div>
        )}
      </ModalContent>
    </Modal>
  );
}
