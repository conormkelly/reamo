/**
 * RoutingModal - View and control track sends/receives/hardware outputs
 * Shows horizontal faders for each routing with tabs to switch between types.
 */

import { useState, useMemo, useEffect, type ReactElement } from 'react';
import { BottomSheet } from '../../Modal/BottomSheet';
import { useTrack } from '../../../hooks/useTrack';
import { useTrackSkeleton } from '../../../hooks';
import { useReaperStore, getSendsFromTrack, getSendsToTrack } from '../../../store';
import { useReaper } from '../../ReaperProvider';
import { routing as routingCmd } from '../../../core/WebSocketCommands';
import { SendsTab, type SendData } from './SendsTab';
import { ReceivesTab, type ReceiveData } from './ReceivesTab';
import { HardwareTab, type HwOutputData } from './HardwareTab';
import { ROUTING_COLORS } from './routingUtils';

export interface RoutingModalProps {
  /** Whether the modal is open */
  isOpen: boolean;
  /** Called when modal should close */
  onClose: () => void;
  /** Track index to show routing for */
  trackIndex: number;
}

type RoutingTab = 'sends' | 'receives' | 'hardware';

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
      setRoutingSubscription(guid);
      sendCommand(routingCmd.subscribe(guid));

      return () => {
        sendCommand(routingCmd.unsubscribe());
        clearRoutingSubscription();
      };
    }
  }, [isOpen, guid, sendCommand, setRoutingSubscription, clearRoutingSubscription]);

  // Use routing subscription data for sends (real-time updates during drag)
  const trackSends = useMemo((): SendData[] => {
    if (routingSends.length > 0) {
      return routingSends.map((s) => ({
        srcTrackIdx: trackIndex,
        destTrackIdx: -1,
        sendIndex: s.sendIndex,
        volume: s.volume,
        pan: s.pan,
        muted: s.muted,
        mode: s.mode,
        destName: s.destName,
      }));
    }
    return getSendsFromTrack(sends, trackIndex).map((s) => ({
      ...s,
      destName: '',
    }));
  }, [routingSends, sends, trackIndex]);

  // Use routing subscription data for receives (real-time updates during drag)
  const trackReceives = useMemo((): ReceiveData[] => {
    if (routingReceives.length > 0) {
      return routingReceives.map((r) => ({
        srcTrackIdx: -1,
        destTrackIdx: trackIndex,
        sendIndex: r.receiveIndex,
        volume: r.volume,
        pan: r.pan,
        muted: r.muted,
        mode: r.mode,
        srcName: r.srcName,
      }));
    }
    return getSendsToTrack(sends, trackIndex).map((s) => ({
      ...s,
      srcName: '',
    }));
  }, [routingReceives, sends, trackIndex]);

  // Use routing subscription data for hw outputs
  const hwOutputs: HwOutputData[] = routingHwOutputs;

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

  // Derive effective tab - auto-switch if current selection has no content
  const effectiveTab = useMemo((): RoutingTab => {
    if (activeTab === 'sends' && !hasSends && hasReceives) return 'receives';
    if (activeTab === 'sends' && !hasSends && hasHwOutputs) return 'hardware';
    return activeTab;
  }, [activeTab, hasSends, hasReceives, hasHwOutputs]);

  const isMaster = trackIndex === 0;
  const displayName = trackName || (isMaster ? 'MASTER' : `Track ${trackIndex}`);

  const sendColors = ROUTING_COLORS.send;
  const receiveColors = ROUTING_COLORS.receive;
  const hardwareColors = ROUTING_COLORS.hardware;

  return (
    <BottomSheet
      isOpen={isOpen}
      onClose={onClose}
      ariaLabel={`Routing for ${displayName}`}
    >
      <div className="px-sheet-x pb-sheet-bottom">
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
              effectiveTab === 'sends'
                ? sendColors.tabActive
                : hasSends
                  ? sendColors.tabInactive
                  : sendColors.tabDisabled
            }`}
          >
            Sends ({trackSends.length})
          </button>
          <button
            onClick={() => setActiveTab('receives')}
            disabled={!hasReceives}
            className={`flex-1 py-2 px-4 rounded-lg text-sm font-medium transition-colors ${
              effectiveTab === 'receives'
                ? receiveColors.tabActive
                : hasReceives
                  ? receiveColors.tabInactive
                  : receiveColors.tabDisabled
            }`}
          >
            Receives ({trackReceives.length})
          </button>
          <button
            onClick={() => setActiveTab('hardware')}
            disabled={!hasHwOutputs}
            className={`flex-1 py-2 px-4 rounded-lg text-sm font-medium transition-colors ${
              effectiveTab === 'hardware'
                ? hardwareColors.tabActive
                : hasHwOutputs
                  ? hardwareColors.tabInactive
                  : hardwareColors.tabDisabled
            }`}
          >
            Hardware ({hwOutCount})
          </button>
        </div>

        {/* Scrollable content */}
        <div className="max-h-80 overflow-y-auto -mx-4 px-4">
          <div className="space-y-1">
            {effectiveTab === 'sends' && (
              <SendsTab
                trackIndex={trackIndex}
                sends={trackSends}
                trackNameLookup={trackNameLookup}
              />
            )}

            {effectiveTab === 'receives' && (
              <ReceivesTab
                trackIndex={trackIndex}
                receives={trackReceives}
                trackNameLookup={trackNameLookup}
              />
            )}

            {effectiveTab === 'hardware' && (
              <HardwareTab
                trackIndex={trackIndex}
                hwOutputs={hwOutputs}
                hwOutCount={hwOutCount}
              />
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
