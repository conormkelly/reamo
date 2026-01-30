/**
 * ActionSearch - Searchable action picker with virtualized list
 * Uses TanStack Virtual for efficient rendering of 10k+ actions.
 * Features:
 * - Section filtering (Main, MIDI Editor, etc.)
 * - Word-based fuzzy search (all words must appear, any order)
 * - Sorted on load: named commands first (alphabetically), then by numeric ID
 */

import { useState, useMemo, useRef, useCallback, useEffect } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { Search, ToggleLeft, Loader2, ChevronDown } from 'lucide-react';
import { useReaperStore, type ReaperAction } from '../../store';
import { getSectionName, REAPER_SECTIONS } from '../../core/constants';

/** Row height for virtualizer - touch-friendly 56px */
const ROW_HEIGHT = 56;

/** Overscan for smooth scrolling */
const OVERSCAN = 5;

/** Debounce delay for search input */
const DEBOUNCE_MS = 150;

/** Special value for "All Sections" filter */
const ALL_SECTIONS = -1;

/**
 * Word-based fuzzy search.
 * All query words must appear somewhere in the target string (any order).
 * Handles punctuation like "SWS/AW:" by treating them as word separators.
 */
function matchesWordSearch(target: string, queryWords: string[]): boolean {
  // Normalize target: lowercase, replace common separators with spaces
  const normalizedTarget = target.toLowerCase().replace(/[/:_\-.]/g, ' ');

  // Every query word must appear in the target
  return queryWords.every((word) => normalizedTarget.includes(word));
}

/**
 * Sort actions: named commands first (alphabetically), then native by numeric ID.
 * This matches REAPER's action list ordering.
 * ~5-15ms for 15k items - runs once on cache load, not on every filter.
 */
function sortActions(actions: ReaperAction[]): ReaperAction[] {
  return [...actions].sort((a, b) => {
    const aHasNamed = a.namedId !== null;
    const bHasNamed = b.namedId !== null;

    // Named commands come first
    if (aHasNamed && !bHasNamed) return -1;
    if (!aHasNamed && bHasNamed) return 1;

    // Both named: sort alphabetically by name
    if (aHasNamed && bHasNamed) {
      return a.name.localeCompare(b.name);
    }

    // Both native: sort by numeric command ID
    return a.commandId - b.commandId;
  });
}

interface ActionSearchProps {
  /** Called when user selects an action */
  onSelect: (action: ReaperAction) => void;
  /** Currently selected action ID (for highlighting) */
  selectedActionId?: string;
  /** Optional max height for the list container */
  maxHeight?: number;
  /** Initial section filter (default: ALL_SECTIONS) */
  initialSection?: number;
}

/**
 * Get the stable action ID to store.
 * Uses namedId for SWS/scripts (stable), commandId as string for native actions.
 */
// eslint-disable-next-line react-refresh/only-export-components -- Utility function co-located with component
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
  initialSection = ALL_SECTIONS,
}: ActionSearchProps) {
  const actionCache = useReaperStore((s) => s.actionCache);
  const loading = useReaperStore((s) => s.actionCacheLoading);
  const error = useReaperStore((s) => s.actionCacheError);

  const [query, setQuery] = useState('');
  const [sectionFilter, setSectionFilter] = useState(initialSection);
  const debouncedQuery = useDebounce(query, DEBOUNCE_MS);

  // Get unique sections from action cache for the dropdown
  const availableSections = useMemo(() => {
    const sectionIds = new Set(actionCache.map((a) => a.sectionId));
    return Array.from(sectionIds).sort((a, b) => a - b);
  }, [actionCache]);

  // Sort actions once on cache change (~5-15ms for 15k items)
  const sortedActions = useMemo(() => sortActions(actionCache), [actionCache]);

  // Filter actions by section and search query
  const filtered = useMemo(() => {
    let result = sortedActions;

    // Apply section filter
    if (sectionFilter !== ALL_SECTIONS) {
      result = result.filter((a) => a.sectionId === sectionFilter);
    }

    // Apply text search
    if (debouncedQuery.trim()) {
      const q = debouncedQuery.toLowerCase().trim();

      // Check if query looks like a numeric ID
      const isNumericQuery = /^\d+$/.test(q);

      if (isNumericQuery) {
        // Numeric query: prefix match on command ID
        result = result.filter((a) => String(a.commandId).startsWith(q));
      } else {
        // Word-based search: split query into words, all must match
        const queryWords = q.split(/\s+/).filter((w) => w.length > 0);
        result = result.filter((a) => {
          // Match against name
          if (matchesWordSearch(a.name, queryWords)) return true;
          // Also match against namedId
          if (a.namedId && matchesWordSearch(a.namedId, queryWords)) return true;
          return false;
        });
      }
    }

    return result;
  }, [sortedActions, sectionFilter, debouncedQuery]);

  // Virtualizer setup
  const parentRef = useRef<HTMLDivElement>(null);

  // eslint-disable-next-line react-hooks/incompatible-library -- TanStack Virtual known limitation
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
      <div className="flex items-center justify-center p-8 text-text-secondary">
        <Loader2 className="animate-spin mr-2" size={20} />
        Loading actions...
      </div>
    );
  }

  // Error state
  if (error) {
    return (
      <div className="p-4 text-error-text text-sm">
        Failed to load actions: {error}
      </div>
    );
  }

  // Empty cache state
  if (actionCache.length === 0) {
    return (
      <div className="p-4 text-text-secondary text-sm">
        No actions available. Make sure REAPER is connected.
      </div>
    );
  }

  return (
    <div className="flex flex-col">
      {/* Section filter */}
      <div className="mb-3">
        <label className="block text-xs text-text-secondary mb-1">Section</label>
        <div className="relative">
          <select
            value={sectionFilter}
            onChange={(e) => setSectionFilter(Number(e.target.value))}
            className="w-full px-3 py-2 pr-8 bg-bg-deep border border-border-default rounded text-text-primary appearance-none focus:border-focus-border focus:outline-none"
          >
            <option value={ALL_SECTIONS}>All Sections</option>
            {availableSections.map((sectionId) => (
              <option key={sectionId} value={sectionId}>
                {REAPER_SECTIONS[sectionId] ?? `Section ${sectionId}`}
              </option>
            ))}
          </select>
          <ChevronDown
            className="absolute right-3 top-1/2 -translate-y-1/2 text-text-secondary pointer-events-none"
            size={16}
          />
        </div>
      </div>

      {/* Search input */}
      <div className="relative mb-3">
        <Search
          className="absolute left-3 top-1/2 -translate-y-1/2 text-text-secondary"
          size={18}
        />
        <input
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search by name (e.g., sws selection cons)..."
          className="w-full pl-10 pr-3 py-2 bg-bg-deep border border-border-default rounded text-text-primary placeholder-text-muted focus:border-focus-border focus:outline-none"
          autoFocus
        />
      </div>

      {/* Results count */}
      <div className="text-xs text-text-muted mb-2">
        {filtered.length === sortedActions.length
          ? `${sortedActions.length} actions`
          : `${filtered.length} of ${sortedActions.length} actions`}
        {sectionFilter !== ALL_SECTIONS && (
          <span className="ml-1">
            in {REAPER_SECTIONS[sectionFilter] ?? `Section ${sectionFilter}`}
          </span>
        )}
      </div>

      {/* No results */}
      {filtered.length === 0 && (
        <div className="p-4 text-text-secondary text-sm text-center">
          No matching actions found
        </div>
      )}

      {/* Virtualized list */}
      {filtered.length > 0 && (
        <div
          ref={parentRef}
          className="overflow-auto border border-border-subtle rounded bg-bg-deep"
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
                        ? 'bg-row-selected-bg border-l-2 border-row-selected-border'
                        : 'hover:bg-bg-surface border-l-2 border-transparent'
                    }`}
                  >
                    {/* Toggle indicator */}
                    <div className="flex-shrink-0 w-5">
                      {action.isToggle && (
                        <ToggleLeft size={16} className="text-text-secondary" />
                      )}
                    </div>

                    {/* Action name and details */}
                    <div className="flex-1 min-w-0">
                      <div className="text-sm text-text-primary truncate">
                        {action.name}
                      </div>
                      <div className="text-xs text-text-muted truncate">
                        {action.namedId ?? action.commandId}
                      </div>
                    </div>

                    {/* Section badge */}
                    {action.sectionId !== 0 && (
                      <div className="flex-shrink-0 px-2 py-0.5 text-xs bg-bg-elevated text-text-tertiary rounded">
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
