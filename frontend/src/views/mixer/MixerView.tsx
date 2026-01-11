/**
 * MixerView - Dedicated mixer with banked faders
 *
 * Features:
 * - Responsive channel count based on screen width
 * - Bank-based navigation (no scroll to prevent accidental fader changes)
 * - Mode switching: Volume (max faders) / Mix (full controls) / Sends (future)
 * - Always-visible master track
 */

import { useState, useEffect, useRef, useCallback, type ReactElement } from 'react';
import { ViewHeader } from '../../components';
import { MixerStrip, BankNavigator, MixerModeSelector, type MixerMode } from '../../components/Mixer';
import { MixerLockButton } from '../../components/Actions';
import {
  useResponsiveChannelCount,
  useBankNavigation,
  useTrackSkeleton,
} from '../../hooks';
import { useReaper } from '../../components/ReaperProvider';
import { track } from '../../core/WebSocketCommands';
import { useReaperStore } from '../../store';
import { EMPTY_TRACKS } from '../../store/stableRefs';

/** Storage key for mixer mode preference */
const MODE_STORAGE_KEY = 'reamo-mixer-mode';

/** Fader heights by mode */
const FADER_HEIGHTS: Record<MixerMode, number> = {
  volume: 220,
  mix: 160,
  sends: 180,
};

export function MixerView(): ReactElement {
  const containerRef = useRef<HTMLDivElement>(null);
  const { sendCommand } = useReaper();
  const { totalTracks } = useTrackSkeleton();
  const tracks = useReaperStore((state) => state?.tracks ?? EMPTY_TRACKS);

  // Responsive channel count
  const { channelCount } = useResponsiveChannelCount({
    containerRef,
    showMaster: true,
  });

  // Bank navigation
  const {
    bankStart,
    bankEnd,
    trackIndices,
    canGoBack,
    canGoForward,
    goBack,
    goForward,
    bankDisplay,
  } = useBankNavigation({
    channelCount,
    totalTracks,
  });

  // Mode state with localStorage persistence
  const [mode, setMode] = useState<MixerMode>(() => {
    try {
      const stored = localStorage.getItem(MODE_STORAGE_KEY);
      if (stored === 'volume' || stored === 'mix' || stored === 'sends') {
        return stored;
      }
    } catch {
      // Ignore localStorage errors
    }
    return 'volume';
  });

  // Persist mode to localStorage
  useEffect(() => {
    try {
      localStorage.setItem(MODE_STORAGE_KEY, mode);
    } catch {
      // Ignore localStorage errors
    }
  }, [mode]);

  // Subscribe to current bank of tracks
  const subscribeToBank = useCallback(() => {
    if (totalTracks === 0) return;

    // Subscribe to tracks in current bank plus master
    sendCommand(
      track.subscribe({
        range: { start: bankStart, end: bankEnd },
        includeMaster: true,
      })
    );
  }, [sendCommand, bankStart, bankEnd, totalTracks]);

  // Subscribe when bank changes
  useEffect(() => {
    subscribeToBank();
  }, [subscribeToBank]);

  // Check if we have data for a track
  const hasTrackData = (trackIndex: number): boolean => {
    return !!tracks[trackIndex];
  };

  // Fader height based on mode
  const faderHeight = FADER_HEIGHTS[mode];

  // Hide dB labels on narrow screens (3 or fewer channels) to prevent strip resizing
  const showDbLabel = channelCount > 3;

  return (
    <div
      ref={containerRef}
      className="h-full bg-bg-app text-text-primary p-3 flex flex-col"
    >
      {/* Header - minimal, just settings and connection */}
      <ViewHeader currentView="mixer">
        <MixerLockButton />
      </ViewHeader>

      {/* Main mixer area */}
      <div className="flex-1 flex items-start justify-center gap-2 overflow-hidden pb-2">
        {/* Master track - always visible, on left */}
        <div className="border-r border-border-subtle pr-2">
          {hasTrackData(0) ? (
            <MixerStrip
              trackIndex={0}
              mode={mode}
              faderHeight={faderHeight}
              showDbLabel={showDbLabel}
            />
          ) : (
            // Loading placeholder for master
            <div
              className="bg-bg-surface/50 rounded-lg animate-pulse"
              style={{ width: 80, height: faderHeight + 100 }}
            />
          )}
        </div>

        {/* Channel strips */}
        <div className="flex gap-2">
          {trackIndices.map((trackIndex) => (
            <div key={trackIndex}>
              {hasTrackData(trackIndex) ? (
                <MixerStrip
                  trackIndex={trackIndex}
                  mode={mode}
                  faderHeight={faderHeight}
                  showDbLabel={showDbLabel}
                />
              ) : (
                // Loading placeholder
                <div
                  className="bg-bg-surface/50 rounded-lg animate-pulse"
                  style={{ width: 80, height: faderHeight + 100 }}
                />
              )}
            </div>
          ))}
        </div>
      </div>

      {/* Footer controls - mode selector left, bank navigator right */}
      <div className="flex items-center justify-between pt-2 border-t border-border-subtle">
        <MixerModeSelector mode={mode} onModeChange={setMode} />
        <BankNavigator
          bankDisplay={bankDisplay}
          canGoBack={canGoBack}
          canGoForward={canGoForward}
          onBack={goBack}
          onForward={goForward}
        />
      </div>

      {/* Empty state */}
      {totalTracks === 0 && (
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="text-text-muted text-center">
            <p className="text-lg mb-2">No tracks in project</p>
            <p className="text-sm">Add tracks in REAPER to see them here</p>
          </div>
        </div>
      )}
    </div>
  );
}
