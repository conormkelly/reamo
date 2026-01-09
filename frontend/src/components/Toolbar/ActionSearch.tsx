/**
 * ActionSearch - Searchable action picker with virtualized list
 * Uses TanStack Virtual for efficient rendering of 10k+ actions.
 */

import { useState, useMemo, useRef, useCallback, useEffect } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { Search, ToggleLeft, Loader2 } from 'lucide-react';
import { useReaperStore, type ReaperAction } from '../../store';
import { getSectionName } from '../../core/constants';

/** Row height for virtualizer - touch-friendly 56px */
const ROW_HEIGHT = 56;

/** Overscan for smooth scrolling */
const OVERSCAN = 5;

/** Debounce delay for search input */
const DEBOUNCE_MS = 150;

interface ActionSearchProps {
  /** Called when user selects an action */
  onSelect: (action: ReaperAction) => void;
  /** Currently selected action ID (for highlighting) */
  selectedActionId?: string;
  /** Optional max height for the list container */
  maxHeight?: number;
}

/**
 * Get the stable action ID to store.
 * Uses namedId for SWS/scripts (stable), commandId as string for native actions.
 */
export function getStableActionId(action: ReaperAction): string {
  return action.namedId ?? String(action.commandId);
}

/**
 * Debounce hook for search input
 */
function useDebounce<T>(value: T, delay: number): T {
  const [debouncedValue, setDebouncedValue] = useState(value);

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedValue(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);

  return debouncedValue;
}

export function ActionSearch({
  onSelect,
  selectedActionId,
  maxHeight = 400,
}: ActionSearchProps) {
  const actionCache = useReaperStore((s) => s.actionCache);
  const loading = useReaperStore((s) => s.actionCacheLoading);
  const error = useReaperStore((s) => s.actionCacheError);

  const [query, setQuery] = useState('');
  const debouncedQuery = useDebounce(query, DEBOUNCE_MS);

  // Filter actions by name or command ID
  const filtered = useMemo(() => {
    if (!debouncedQuery.trim()) return actionCache;

    const q = debouncedQuery.toLowerCase().trim();

    // Check if query looks like a numeric ID
    const isNumericQuery = /^\d+$/.test(q);

    return actionCache.filter((a) => {
      // Match by name (case-insensitive substring)
      if (a.name.toLowerCase().includes(q)) return true;

      // Match by command ID (prefix match for numeric queries)
      if (isNumericQuery && String(a.commandId).startsWith(q)) return true;

      // Match by named ID (for SWS/scripts)
      if (a.namedId?.toLowerCase().includes(q)) return true;

      return false;
    });
  }, [actionCache, debouncedQuery]);

  // Virtualizer setup
  const parentRef = useRef<HTMLDivElement>(null);

  const virtualizer = useVirtualizer({
    count: filtered.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => ROW_HEIGHT,
    overscan: OVERSCAN,
  });

  // Handle row click
  const handleRowClick = useCallback(
    (action: ReaperAction) => {
      onSelect(action);
    },
    [onSelect]
  );

  // Loading state
  if (loading) {
    return (
      <div className="flex items-center justify-center p-8 text-gray-400">
        <Loader2 className="animate-spin mr-2" size={20} />
        Loading actions...
      </div>
    );
  }

  // Error state
  if (error) {
    return (
      <div className="p-4 text-red-400 text-sm">
        Failed to load actions: {error}
      </div>
    );
  }

  // Empty cache state
  if (actionCache.length === 0) {
    return (
      <div className="p-4 text-gray-400 text-sm">
        No actions available. Make sure REAPER is connected.
      </div>
    );
  }

  return (
    <div className="flex flex-col">
      {/* Search input */}
      <div className="relative mb-3">
        <Search
          className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400"
          size={18}
        />
        <input
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search actions by name or ID..."
          className="w-full pl-10 pr-3 py-2 bg-gray-900 border border-gray-600 rounded text-white placeholder-gray-500 focus:border-blue-500 focus:outline-none"
          autoFocus
        />
      </div>

      {/* Results count */}
      <div className="text-xs text-gray-500 mb-2">
        {filtered.length === actionCache.length
          ? `${actionCache.length} actions`
          : `${filtered.length} of ${actionCache.length} actions`}
      </div>

      {/* No results */}
      {filtered.length === 0 && (
        <div className="p-4 text-gray-400 text-sm text-center">
          No matching actions found
        </div>
      )}

      {/* Virtualized list */}
      {filtered.length > 0 && (
        <div
          ref={parentRef}
          className="overflow-auto border border-gray-700 rounded bg-gray-900"
          style={{ maxHeight }}
        >
          <div
            style={{
              height: virtualizer.getTotalSize(),
              width: '100%',
              position: 'relative',
            }}
          >
            {virtualizer.getVirtualItems().map((virtualRow) => {
              const action = filtered[virtualRow.index];
              const stableId = getStableActionId(action);
              const isSelected = selectedActionId === stableId;

              return (
                <div
                  key={virtualRow.key}
                  style={{
                    position: 'absolute',
                    top: 0,
                    left: 0,
                    width: '100%',
                    height: ROW_HEIGHT,
                    transform: `translateY(${virtualRow.start}px)`,
                  }}
                >
                  <button
                    onClick={() => handleRowClick(action)}
                    className={`w-full h-full px-3 flex items-center gap-3 text-left transition-colors ${
                      isSelected
                        ? 'bg-blue-600/30 border-l-2 border-blue-500'
                        : 'hover:bg-gray-800 border-l-2 border-transparent'
                    }`}
                  >
                    {/* Toggle indicator */}
                    <div className="flex-shrink-0 w-5">
                      {action.isToggle && (
                        <ToggleLeft size={16} className="text-gray-400" />
                      )}
                    </div>

                    {/* Action name and details */}
                    <div className="flex-1 min-w-0">
                      <div className="text-sm text-white truncate">
                        {action.name}
                      </div>
                      <div className="text-xs text-gray-500 truncate">
                        {action.namedId ?? action.commandId}
                      </div>
                    </div>

                    {/* Section badge */}
                    {action.sectionId !== 0 && (
                      <div className="flex-shrink-0 px-2 py-0.5 text-xs bg-gray-700 text-gray-300 rounded">
                        {getSectionName(action.sectionId)}
                      </div>
                    )}
                  </button>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </div>
  );
}
