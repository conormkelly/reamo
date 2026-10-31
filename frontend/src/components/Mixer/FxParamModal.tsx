/**
 * FxParamModal - View and control FX parameters
 *
 * Shows parameter list with sliders for real-time control.
 * The list is virtualized, and values arrive at 30Hz for a window of
 * parameters around the rows on screen (useFxParamSubscription), so plugins
 * with hundreds of parameters page through it as the list scrolls.
 * Supports a search filter; its matches are subscribed by parameter index.
 * Uses gesture commands for proper undo coalescing.
 */

import { useEffect, useCallback, useRef, useState, useMemo, type ReactElement } from 'react';
import { LoaderCircle, Search, X } from 'lucide-react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { BottomSheet } from '../Modal/BottomSheet';
import { useReaper } from '../../hooks/useReaper';
import { useFxParamSubscription } from '../../hooks/useFxParamSubscription';
import { useReaperStore } from '../../store';
import { trackFxParams, gesture } from '../../core/WebSocketCommands';
import type { FxParamsSkeletonPayload } from '../../core/WebSocketTypes';

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

/** Estimated row height in px (py-3 + 16px name line + gap-1 + h-8 slider); rows are measured */
const PARAM_ROW_ESTIMATE_PX = 84;

/** Space between rows in px (0.375rem) */
const PARAM_ROW_GAP_PX = 6;

/** Rows rendered beyond each end of the visible ones */
const RENDER_OVERSCAN = 5;

/** Double-tap detection threshold in ms */
const DOUBLE_TAP_THRESHOLD = 300;

/**
 * Single parameter row with slider
 * Double-tap slider to reset to 0.5 (default value)
 * Until the parameter's value has arrived the slider is disabled, so a drag
 * or double-tap can't send a value judged against a placeholder.
 */
function ParamRow({
  paramIndex,
  name,
  value,
  formatted,
  hasValue,
  onValueChange,
  onDragStart,
  onDragEnd,
  onReset,
}: {
  paramIndex: number;
  name: string;
  value: number;
  formatted: string;
  hasValue: boolean;
  onValueChange: (value: number) => void;
  onDragStart: () => void;
  onDragEnd: () => void;
  onReset: () => void;
}): ReactElement {
  const sliderRef = useRef<HTMLInputElement>(null);
  const isDraggingRef = useRef(false);
  const lastTapTimeRef = useRef(0);

  const handlePointerDown = useCallback(() => {
    if (!hasValue) return;
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
  }, [hasValue, onDragStart, onReset]);

  const handlePointerUp = useCallback(() => {
    if (isDraggingRef.current) {
      isDraggingRef.current = false;
      onDragEnd();
    }
  }, [onDragEnd]);

  const handleChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      if (!hasValue) return;
      const newValue = parseFloat(e.target.value);
      onValueChange(newValue);
    },
    [hasValue, onValueChange]
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

  // The list unmounts rows scrolled out of view: end a gesture still open,
  // or its undo point is never closed
  const onDragEndRef = useRef(onDragEnd);
  useEffect(() => {
    onDragEndRef.current = onDragEnd;
  }, [onDragEnd]);
  useEffect(() => {
    return () => {
      if (isDraggingRef.current) {
        isDraggingRef.current = false;
        onDragEndRef.current();
      }
    };
  }, []);

  return (
    <div data-param-index={paramIndex} className="flex flex-col gap-1 py-3 px-3 bg-bg-surface rounded-lg">
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
        aria-label={name}
        min={0}
        max={1}
        step={0.001}
        value={value}
        disabled={!hasValue}
        onChange={handleChange}
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerUp}
        className="w-full h-8 accent-accent cursor-pointer touch-pan-y disabled:cursor-default disabled:opacity-40"
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
  const setFxParamSkeletonError = useReaperStore((s) => s.setFxParamSkeletonError);
  const retryFxParamSkeleton = useReaperStore((s) => s.retryFxParamSkeleton);
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

  // Filter skeleton based on search
  const { filteredParams, filteredIndices } = useMemo(() => {
    if (!skeleton) return { filteredParams: [], filteredIndices: [] };

    const searchLower = search.toLowerCase().trim();
    const filtered: Array<{ idx: number; name: string }> = [];

    for (let i = 0; i < skeleton.length; i++) {
      if (!searchLower || skeleton[i].toLowerCase().includes(searchLower)) {
        filtered.push({ idx: i, name: skeleton[i] });
      }
    }

    return { filteredParams: filtered, filteredIndices: filtered.map((p) => p.idx) };
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

  // Fetch the skeleton whenever the store marks it loading: on open without a
  // cached skeleton, when a trackFxParams event's paramCount or nameHash
  // differs from it (handleFxParamsEvent), and on Retry. The skeleton is
  // stored with the nameHash getParams returns, the hash the events carry, so
  // it is fetched again only when the names change. A failed fetch clears
  // loading and shows the error with a Retry button; it is never retried in a
  // loop. Without a skeleton nothing is subscribed and no event arrives, so
  // after a failed first fetch only Retry fetches again. A response that
  // arrives after the modal closed or switched FX is dropped.
  useEffect(() => {
    if (!isOpen || !subscription || !skeletonLoading) return;

    let cancelled = false;
    const fetchSkeleton = async () => {
      try {
        const response = await sendCommandAsync(trackFxParams.getParams(trackGuid, fxGuid));
        if (cancelled) return;
        const resp = response as { success?: boolean; payload?: Partial<FxParamsSkeletonPayload> };
        const payload = resp?.success ? resp.payload : undefined;
        if (Array.isArray(payload?.params) && typeof payload.nameHash === 'number') {
          setFxParamSkeleton(payload.params, payload.nameHash);
        } else {
          setFxParamSkeletonError('Invalid skeleton response');
        }
      } catch (err) {
        if (cancelled) return;
        setFxParamSkeletonError(err instanceof Error ? err.message : 'Failed to fetch parameters');
      }
    };

    fetchSkeleton();
    return () => {
      cancelled = true;
    };
  }, [isOpen, subscription, skeletonLoading, trackGuid, fxGuid, sendCommandAsync, setFxParamSkeleton, setFxParamSkeletonError]);

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

  // eslint-disable-next-line react-hooks/incompatible-library -- TanStack Virtual known limitation
  const rowVirtualizer = useVirtualizer({
    count: filteredParams.length,
    getScrollElement: () => scrollContainerRef.current,
    estimateSize: () => PARAM_ROW_ESTIMATE_PX,
    gap: PARAM_ROW_GAP_PX,
    overscan: RENDER_OVERSCAN,
    getItemKey: (index) => filteredParams[index].idx,
  });
  const virtualRows = rowVirtualizer.getVirtualItems();

  // Values follow the rows on screen; read range after getVirtualItems(),
  // which computes it
  useFxParamSubscription({
    enabled: isOpen && subscription !== null,
    trackGuid,
    fxGuid,
    paramIndices: filteredIndices,
    visibleRange: rowVirtualizer.range,
    sendCommand,
  });

  // A list with different rows (a filter, or a skeleton with other names)
  // is shown from its top, as useFxParamSubscription expects; an equal list
  // (a refetched skeleton with the same names) keeps its scroll position
  const listKey = useMemo(() => filteredIndices.join(','), [filteredIndices]);
  useEffect(() => {
    rowVirtualizer.scrollToOffset(0);
  }, [listKey, rowVirtualizer]);

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
          <div className="py-8 flex flex-col items-center gap-3 text-center">
            <p className="text-error-text text-base">{skeletonError}</p>
            <button
              type="button"
              onClick={retryFxParamSkeleton}
              aria-label="Retry loading parameters"
              className="min-h-11 min-w-11 px-4 py-2 text-base font-medium rounded-lg bg-bg-elevated hover:bg-bg-hover text-text-primary transition-colors"
            >
              Retry
            </button>
          </div>
        )}

        {/* Loading state */}
        {skeletonLoading && !skeleton && (
          <div className="py-8 flex flex-col items-center gap-2 text-text-muted">
            <LoaderCircle size={24} className="animate-spin" />
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
            data-testid="fx-param-list"
            className="max-h-80 overflow-y-auto -mx-4 px-4"
          >
            <div
              role="list"
              aria-label="Parameters"
              className="relative"
              style={{ height: rowVirtualizer.getTotalSize() }}
            >
              {virtualRows.map((row) => {
                const { idx, name } = filteredParams[row.index];
                const valueData = paramValues.get(idx);
                return (
                  <div
                    key={row.key}
                    role="listitem"
                    aria-setsize={filteredParams.length}
                    aria-posinset={row.index + 1}
                    data-index={row.index}
                    ref={rowVirtualizer.measureElement}
                    className="absolute top-0 left-0 w-full"
                    style={{ transform: `translateY(${row.start}px)` }}
                  >
                    <ParamRow
                      paramIndex={idx}
                      name={name}
                      value={valueData?.value ?? 0}
                      formatted={valueData?.formatted ?? '—'}
                      hasValue={valueData !== undefined}
                      onValueChange={(v) => handleValueChange(idx, v)}
                      onDragStart={() => handleDragStart(idx)}
                      onDragEnd={() => handleDragEnd(idx)}
                      onReset={() => handleReset(idx)}
                    />
                  </div>
                );
              })}
            </div>
          </div>
        )}
      </div>
    </BottomSheet>
  );
}
