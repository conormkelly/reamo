/**
 * FxParamModal - View and control FX parameters
 *
 * Shows parameter list with sliders for real-time control.
 * Uses subscription-based updates at 30Hz.
 * Supports search filter with sparse index subscription mode.
 * Uses gesture commands for proper undo coalescing.
 */

import { useEffect, useCallback, useRef, useState, useMemo, type ReactElement } from 'react';
import { Loader2, Search, X } from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import { trackFxParams, gesture } from '../../core/WebSocketCommands';

export interface FxParamModalProps {
  /** Whether the modal is open */
  isOpen: boolean;
  /** Called when modal should close */
  onClose: () => void;
  /** Track GUID */
  trackGuid: string;
  /** FX GUID */
  fxGuid: string;
  /** FX name for display */
  fxName: string;
}

/** Max params to subscribe to when filtering (prevents overload) */
const MAX_FILTERED_INDICES = 50;

/** Double-tap detection threshold in ms */
const DOUBLE_TAP_THRESHOLD = 300;

/**
 * Single parameter row with slider
 * Double-tap slider to reset to 0.5 (default value)
 */
function ParamRow({
  name,
  value,
  formatted,
  onValueChange,
  onDragStart,
  onDragEnd,
  onReset,
}: {
  name: string;
  value: number;
  formatted: string;
  onValueChange: (value: number) => void;
  onDragStart: () => void;
  onDragEnd: () => void;
  onReset: () => void;
}): ReactElement {
  const sliderRef = useRef<HTMLInputElement>(null);
  const isDraggingRef = useRef(false);
  const lastTapTimeRef = useRef(0);

  const handlePointerDown = useCallback(() => {
    const now = Date.now();
    const timeSinceLastTap = now - lastTapTimeRef.current;

    // Detect double-tap
    if (timeSinceLastTap < DOUBLE_TAP_THRESHOLD) {
      // Double-tap detected - reset to default
      onReset();
      lastTapTimeRef.current = 0; // Reset to prevent triple-tap
      return;
    }

    lastTapTimeRef.current = now;
    isDraggingRef.current = true;
    onDragStart();
  }, [onDragStart, onReset]);

  const handlePointerUp = useCallback(() => {
    if (isDraggingRef.current) {
      isDraggingRef.current = false;
      onDragEnd();
    }
  }, [onDragEnd]);

  const handleChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const newValue = parseFloat(e.target.value);
      onValueChange(newValue);
    },
    [onValueChange]
  );

  // Handle pointer up outside of slider
  useEffect(() => {
    const handleGlobalPointerUp = () => {
      if (isDraggingRef.current) {
        isDraggingRef.current = false;
        onDragEnd();
      }
    };

    document.addEventListener('pointerup', handleGlobalPointerUp);
    document.addEventListener('pointercancel', handleGlobalPointerUp);

    return () => {
      document.removeEventListener('pointerup', handleGlobalPointerUp);
      document.removeEventListener('pointercancel', handleGlobalPointerUp);
    };
  }, [onDragEnd]);

  return (
    <div className="flex flex-col gap-1 py-3 px-3 bg-bg-surface rounded-lg">
      {/* Name and value - 16px base text */}
      <div className="flex items-center justify-between gap-2">
        <span className="text-base text-text-primary truncate flex-1">{name}</span>
        <span className="text-sm text-text-secondary font-mono min-w-16 text-right">
          {formatted}
        </span>
      </div>

      {/* Slider */}
      <input
        ref={sliderRef}
        type="range"
        min={0}
        max={1}
        step={0.001}
        value={value}
        onChange={handleChange}
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerUp}
        className="w-full h-8 accent-accent cursor-pointer touch-pan-y"
      />
    </div>
  );
}

export function FxParamModal({
  isOpen,
  onClose,
  trackGuid,
  fxGuid,
  fxName,
}: FxParamModalProps): ReactElement {
  const { sendCommand, sendCommandAsync } = useReaper();

  // State from store
  const subscription = useReaperStore((s) => s.fxParamSubscription);
  const skeleton = useReaperStore((s) => s.fxParamSkeleton);
  const skeletonLoading = useReaperStore((s) => s.fxParamSkeletonLoading);
  const skeletonError = useReaperStore((s) => s.fxParamSkeletonError);
  const paramValues = useReaperStore((s) => s.fxParamValues);
  const paramCount = useReaperStore((s) => s.fxParamCount);
  const setFxParamSubscription = useReaperStore((s) => s.setFxParamSubscription);
  const setFxParamSkeleton = useReaperStore((s) => s.setFxParamSkeleton);
  const setFxParamSkeletonLoading = useReaperStore((s) => s.setFxParamSkeletonLoading);
  const setFxParamSkeletonError = useReaperStore((s) => s.setFxParamSkeletonError);
  const clearFxParamSubscription = useReaperStore((s) => s.clearFxParamSubscription);

  // Local search state
  const [search, setSearch] = useState('');
  const scrollContainerRef = useRef<HTMLDivElement>(null);

  // Reset search when modal opens
  useEffect(() => {
    if (isOpen) {
      setSearch('');
    }
  }, [isOpen]);

  // Filter skeleton based on search and compute indices to subscribe
  const { filteredParams, subscribedIndices } = useMemo(() => {
    if (!skeleton) return { filteredParams: [], subscribedIndices: [] };

    const searchLower = search.toLowerCase().trim();
    const filtered: Array<{ idx: number; name: string }> = [];

    for (let i = 0; i < skeleton.length; i++) {
      if (!searchLower || skeleton[i].toLowerCase().includes(searchLower)) {
        filtered.push({ idx: i, name: skeleton[i] });
      }
    }

    // Limit subscribed indices to prevent overload
    const indices = filtered.slice(0, MAX_FILTERED_INDICES).map((p) => p.idx);

    return { filteredParams: filtered, subscribedIndices: indices };
  }, [skeleton, search]);

  // Subscribe on open, unsubscribe on close
  useEffect(() => {
    if (!isOpen) return;

    // Set up subscription in store
    setFxParamSubscription(trackGuid, fxGuid, fxName);

    return () => {
      sendCommand(trackFxParams.unsubscribe());
      clearFxParamSubscription();
    };
  }, [isOpen, trackGuid, fxGuid, fxName, sendCommand, setFxParamSubscription, clearFxParamSubscription]);

  // Fetch skeleton if needed
  useEffect(() => {
    if (!isOpen || !subscription) return;
    if (skeleton !== null && !skeletonLoading) return;

    const fetchSkeleton = async () => {
      setFxParamSkeletonLoading(true);
      try {
        const response = await sendCommandAsync(trackFxParams.getParams(trackGuid, fxGuid));
        // Response format: { success: true, payload: { trackGuid, fxGuid, paramCount, params: string[] } }
        const resp = response as { success?: boolean; payload?: { params?: string[]; paramCount?: number } };
        if (resp?.success && resp.payload?.params) {
          // TODO: Backend getParams doesn't return nameHash yet (v1.1 feature).
          // Using paramCount as proxy - skeleton won't refresh if param names change
          // without count changing. Real hash comes from trackFxParams events.
          const initialHash = resp.payload.paramCount ?? resp.payload.params.length;
          setFxParamSkeleton(resp.payload.params, initialHash);
        } else {
          setFxParamSkeletonError('Invalid skeleton response');
        }
      } catch (err) {
        setFxParamSkeletonError(err instanceof Error ? err.message : 'Failed to fetch parameters');
      }
    };

    fetchSkeleton();
  }, [isOpen, subscription, skeleton, skeletonLoading, trackGuid, fxGuid, sendCommandAsync, setFxParamSkeleton, setFxParamSkeletonLoading, setFxParamSkeletonError]);

  // Update subscription with filtered indices
  useEffect(() => {
    if (!isOpen || !subscription || subscribedIndices.length === 0) return;

    sendCommand(trackFxParams.subscribe(trackGuid, fxGuid, { indices: subscribedIndices }));
  }, [isOpen, subscription, trackGuid, fxGuid, subscribedIndices, sendCommand]);

  // Handle skeleton refresh on hash mismatch
  useEffect(() => {
    if (!isOpen || !subscription) return;
    if (paramCount === 0) return;

    // needsSkeletonRefresh is checked in handleFxParamsEvent, which sets skeletonLoading=true
    // This effect is triggered when that happens
    if (skeletonLoading && skeleton !== null) {
      // Refetch skeleton
      const fetchSkeleton = async () => {
        try {
          const response = await sendCommandAsync(trackFxParams.getParams(trackGuid, fxGuid));
          const resp = response as { success?: boolean; payload?: { params?: string[]; paramCount?: number } };
          if (resp?.success && resp.payload?.params) {
            const newHash = resp.payload.paramCount ?? resp.payload.params.length;
            setFxParamSkeleton(resp.payload.params, newHash);
          }
        } catch (err) {
          setFxParamSkeletonError(err instanceof Error ? err.message : 'Failed to refresh parameters');
        }
      };
      fetchSkeleton();
    }
  }, [isOpen, subscription, paramCount, skeletonLoading, skeleton, trackGuid, fxGuid, sendCommandAsync, setFxParamSkeleton, setFxParamSkeletonError]);

  // Handle value change
  const handleValueChange = useCallback(
    (paramIdx: number, value: number) => {
      sendCommand(trackFxParams.set(trackGuid, fxGuid, paramIdx, value));
    },
    [sendCommand, trackGuid, fxGuid]
  );

  // Handle drag start (gesture/start)
  const handleDragStart = useCallback(
    (paramIdx: number) => {
      sendCommand(gesture.startFxParam(trackGuid, fxGuid, paramIdx));
    },
    [sendCommand, trackGuid, fxGuid]
  );

  // Handle drag end (gesture/end)
  const handleDragEnd = useCallback(
    (paramIdx: number) => {
      sendCommand(gesture.endFxParam(trackGuid, fxGuid, paramIdx));
    },
    [sendCommand, trackGuid, fxGuid]
  );

  // Handle reset (double-tap to 0.5)
  const handleReset = useCallback(
    (paramIdx: number) => {
      // Start gesture, set to 0.5, end gesture (single undo point)
      sendCommand(gesture.startFxParam(trackGuid, fxGuid, paramIdx));
      sendCommand(trackFxParams.set(trackGuid, fxGuid, paramIdx, 0.5));
      sendCommand(gesture.endFxParam(trackGuid, fxGuid, paramIdx));
    },
    [sendCommand, trackGuid, fxGuid]
  );

  // Build param list with values from filtered params
  const paramList = useMemo(() => {
    return filteredParams.map(({ idx, name }) => {
      const valueData = paramValues.get(idx);
      return {
        idx,
        name,
        value: valueData?.value ?? 0,
        formatted: valueData?.formatted ?? '—',
        hasValue: valueData !== undefined,
      };
    });
  }, [filteredParams, paramValues]);

  return (
    <BottomSheet
      isOpen={isOpen}
      onClose={onClose}
      ariaLabel={`Parameters for ${fxName}`}
    >
      <div className="px-sheet-x pb-sheet-bottom">
        {/* Header */}
        <div className="text-center mb-3 pt-1">
          <h2 className="text-lg font-semibold text-text-primary truncate">
            {fxName}
          </h2>
          {paramCount > 0 && (
            <p className="text-xs text-text-muted mt-0.5">
              {filteredParams.length === paramCount
                ? `${paramCount} parameter${paramCount !== 1 ? 's' : ''}`
                : `${filteredParams.length} of ${paramCount} parameters`}
            </p>
          )}
        </div>

        {/* Search input */}
        {skeleton && skeleton.length > 0 && (
          <div className="relative mb-3">
            <Search
              size={16}
              className="absolute left-3 top-1/2 -translate-y-1/2 text-text-muted"
            />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Filter parameters..."
              className="w-full pl-9 pr-9 py-2.5 bg-bg-surface rounded-lg text-base text-text-primary placeholder:text-text-muted focus:outline-none focus:ring-2 focus:ring-accent/50"
            />
            {search && (
              <button
                onClick={() => setSearch('')}
                className="absolute right-3 top-1/2 -translate-y-1/2 text-text-muted hover:text-text-secondary"
              >
                <X size={16} />
              </button>
            )}
          </div>
        )}

        {/* Error state */}
        {skeletonError && (
          <div className="py-8 text-center text-error-text text-base">
            {skeletonError}
          </div>
        )}

        {/* Loading state */}
        {skeletonLoading && !skeleton && (
          <div className="py-8 flex flex-col items-center gap-2 text-text-muted">
            <Loader2 size={24} className="animate-spin" />
            <span className="text-base">Loading parameters...</span>
          </div>
        )}

        {/* Empty state - no params on FX */}
        {skeleton && skeleton.length === 0 && (
          <div className="py-8 text-center text-text-muted text-base">
            No parameters available
          </div>
        )}

        {/* Empty search results */}
        {skeleton && skeleton.length > 0 && filteredParams.length === 0 && (
          <div className="py-8 text-center text-text-muted text-base">
            No matching parameters
          </div>
        )}

        {/* Parameter list */}
        {skeleton && skeleton.length > 0 && filteredParams.length > 0 && (
          <div
            ref={scrollContainerRef}
            className="max-h-80 overflow-y-auto -mx-4 px-4"
          >
            <div className="space-y-1.5">
              {paramList.map((param) => (
                <ParamRow
                  key={param.idx}
                  name={param.name}
                  value={param.value}
                  formatted={param.formatted}
                  onValueChange={(v) => handleValueChange(param.idx, v)}
                  onDragStart={() => handleDragStart(param.idx)}
                  onDragEnd={() => handleDragEnd(param.idx)}
                  onReset={() => handleReset(param.idx)}
                />
              ))}
            </div>

            {/* Truncation notice */}
            {filteredParams.length > MAX_FILTERED_INDICES && (
              <div className="mt-3 text-center text-sm text-text-muted">
                Showing {MAX_FILTERED_INDICES} of {filteredParams.length} matches
              </div>
            )}
          </div>
        )}
      </div>
    </BottomSheet>
  );
}
