/**
 * NavigateItemInfoBar Component
 * Shows item info when items are selected in the timeline.
 *
 * Mode-based display:
 * - 0 items selected: "Tap an item to select" message
 * - 1 item selected: Full single-item controls (take nav, color, more)
 * - 2+ items selected: Batch mode with Group button for batch operations
 *
 * Features:
 * - X button to clear selection
 * - Selection count pill (opens selection refinement sheet)
 * - Group icon (2+ selected) opens batch operations sheet
 *
 * Note: Track filter dropdown removed in Phase 2.5 - items are now visible
 * across all tracks in multi-track lanes, no need for single-track filtering.
 */

import {
  useState,
  useEffect,
  useMemo,
  useCallback,
  useRef,
  type ReactElement,
} from 'react';
import {
  ChevronLeft,
  ChevronRight,
  MoreHorizontal,
  Check,
  Scissors,
  Trash2,
  Lock,
  Unlock,
  X,
  ChevronUp,
  ChevronDown,
  Group,
  Palette,
} from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTimeFormatters } from '../../hooks';
import { item as itemCmd, take as takeCmd } from '../../core/WebSocketCommands';
import { hexToReaperColor, reaperColorToHexWithFallback, formatTime } from '../../utils';
import { DEFAULT_ITEM_COLOR } from '../../constants/colors';
import { ColorPickerInput } from '../Toolbar/ColorPickerInput';
import { EMPTY_SKELETON, EMPTY_ITEMS } from '../../store/stableRefs';
import type { SkeletonTrack, WSItem } from '../../core/WebSocketTypes';

export interface NavigateItemInfoBarProps {
  className?: string;
}

/** Group items by track for details sheet */
interface TrackGroup {
  trackIdx: number;
  trackName: string;
  items: WSItem[];
  isExpanded: boolean;
}

export function NavigateItemInfoBar({
  className = '',
}: NavigateItemInfoBarProps): ReactElement | null {
  const { sendCommand, sendAsync, connected } = useReaper();
  const { formatBeats, formatDuration } = useTimeFormatters();

  // Store state
  const items = useReaperStore((s) => s?.items ?? EMPTY_ITEMS);
  const trackSkeleton = useReaperStore((s) => s?.trackSkeleton ?? EMPTY_SKELETON) as readonly SkeletonTrack[];
  const itemSelectionModeActive = useReaperStore((s) => s.itemSelectionModeActive);
  const exitItemSelectionMode = useReaperStore((s) => s.exitItemSelectionMode);

  // Derive selection from items (REAPER is source of truth)
  const selectedItems = useMemo(() => items.filter((i) => i.selected), [items]);
  const selectedCount = selectedItems.length;

  // Single item mode: when exactly 1 item is selected, that's the display item
  const singleItem = selectedCount === 1 ? selectedItems[0] : null;

  // Local state for sheets
  const [showItemSheet, setShowItemSheet] = useState(false);
  const [showSelectionSheet, setShowSelectionSheet] = useState(false);
  const [showBatchSheet, setShowBatchSheet] = useState(false);

  // Accordion state for selection details sheet
  const [expandedTracks, setExpandedTracks] = useState<Set<number>>(new Set());

  // Notes state (fetched on-demand for single item)
  const [isEditingNotes, setIsEditingNotes] = useState(false);
  const [notesValue, setNotesValue] = useState('');
  const [notesLoading, setNotesLoading] = useState(false);
  const notesInputRef = useRef<HTMLTextAreaElement>(null);

  // Get track name from skeleton
  const getTrackNameFromSkeleton = useCallback(
    (trackIdx: number): string | null => {
      return trackSkeleton[trackIdx]?.n ?? null;
    },
    [trackSkeleton]
  );

  // ========== Single Item Handlers ==========

  // Take navigation (only for single item)
  const handlePrevTake = useCallback(() => {
    if (!singleItem || singleItem.activeTakeIdx <= 0) return;
    sendCommand(
      itemCmd.setActiveTake(singleItem.trackIdx, singleItem.itemIdx, singleItem.activeTakeIdx - 1)
    );
  }, [singleItem, sendCommand]);

  const handleNextTake = useCallback(() => {
    if (!singleItem || singleItem.activeTakeIdx >= singleItem.takeCount - 1) return;
    sendCommand(
      itemCmd.setActiveTake(singleItem.trackIdx, singleItem.itemIdx, singleItem.activeTakeIdx + 1)
    );
  }, [singleItem, sendCommand]);

  // Color picker handler (single item)
  const handleColorChange = useCallback(
    (color: string) => {
      if (!singleItem) return;
      const reaperColor = hexToReaperColor(color);
      sendCommand(
        itemCmd.setColor(singleItem.trackIdx, singleItem.itemIdx, reaperColor)
      );
    },
    [singleItem, sendCommand]
  );

  // Item action handlers (single item)
  const handleCropToActive = useCallback(() => {
    sendCommand(takeCmd.cropToActive());
  }, [sendCommand]);

  const handleDeleteTake = useCallback(() => {
    if (singleItem && singleItem.takeCount > 1) {
      sendCommand(takeCmd.delete());
    }
  }, [singleItem, sendCommand]);

  const handleToggleLock = useCallback(() => {
    if (!singleItem) return;
    sendCommand(itemCmd.setLock(singleItem.trackIdx, singleItem.itemIdx, singleItem.locked ? 0 : 1));
  }, [singleItem, sendCommand]);

  // Notes handlers (single item)
  const handleNotesSubmit = useCallback(() => {
    if (!singleItem) return;
    sendCommand(itemCmd.setNotes(singleItem.trackIdx, singleItem.itemIdx, notesValue));
    setIsEditingNotes(false);
  }, [singleItem, sendCommand, notesValue]);

  const handleNotesKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      setIsEditingNotes(false);
    }
  }, []);

  // Reset notes when single item changes
  useEffect(() => {
    setNotesValue('');
    setIsEditingNotes(false);
  }, [singleItem?.guid]);

  // Fetch notes when sheet opens (if item has notes)
  useEffect(() => {
    if (!showItemSheet || !singleItem?.hasNotes || !connected) return;
    if (notesValue) return; // Already fetched

    const fetchNotes = async () => {
      setNotesLoading(true);
      try {
        const cmd = itemCmd.getNotes(singleItem.trackIdx, singleItem.itemIdx);
        const response = await sendAsync(cmd.command, cmd.params) as {
          success: boolean;
          payload?: { notes: string };
        };
        if (response.success && response.payload) {
          setNotesValue(response.payload.notes || '');
        }
      } catch {
        // Ignore fetch errors
      } finally {
        setNotesLoading(false);
      }
    };
    fetchNotes();
  }, [showItemSheet, singleItem, connected, sendAsync, notesValue]);

  // Focus notes input when editing starts
  useEffect(() => {
    if (isEditingNotes && !notesLoading && notesInputRef.current) {
      notesInputRef.current.focus();
    }
  }, [isEditingNotes, notesLoading]);

  // ========== Batch Operation Handlers ==========

  // Batch color change
  const handleBatchColorChange = useCallback(
    (color: string) => {
      const reaperColor = hexToReaperColor(color);
      for (const item of selectedItems) {
        sendCommand(itemCmd.setColor(item.trackIdx, item.itemIdx, reaperColor));
      }
    },
    [selectedItems, sendCommand]
  );

  // Batch lock all
  const handleBatchLockAll = useCallback(() => {
    for (const item of selectedItems) {
      if (!item.locked) {
        sendCommand(itemCmd.setLock(item.trackIdx, item.itemIdx, 1));
      }
    }
  }, [selectedItems, sendCommand]);

  // Batch unlock all
  const handleBatchUnlockAll = useCallback(() => {
    for (const item of selectedItems) {
      if (item.locked) {
        sendCommand(itemCmd.setLock(item.trackIdx, item.itemIdx, 0));
      }
    }
  }, [selectedItems, sendCommand]);

  // Batch next take (for all items with multiple takes)
  const handleBatchNextTake = useCallback(() => {
    for (const item of selectedItems) {
      if (item.takeCount > 1 && item.activeTakeIdx < item.takeCount - 1) {
        sendCommand(itemCmd.setActiveTake(item.trackIdx, item.itemIdx, item.activeTakeIdx + 1));
      }
    }
  }, [selectedItems, sendCommand]);

  // Batch prev take (for all items with multiple takes)
  const handleBatchPrevTake = useCallback(() => {
    for (const item of selectedItems) {
      if (item.takeCount > 1 && item.activeTakeIdx > 0) {
        sendCommand(itemCmd.setActiveTake(item.trackIdx, item.itemIdx, item.activeTakeIdx - 1));
      }
    }
  }, [selectedItems, sendCommand]);

  // Check if any selected items have multiple takes
  const anyHaveMultipleTakes = useMemo(
    () => selectedItems.some((i) => i.takeCount > 1),
    [selectedItems]
  );

  // Check lock states for batch UI
  const allLocked = useMemo(
    () => selectedItems.length > 0 && selectedItems.every((i) => i.locked),
    [selectedItems]
  );
  const anyLocked = useMemo(
    () => selectedItems.some((i) => i.locked),
    [selectedItems]
  );

  // ========== Common Handlers ==========

  // Exit mode handler
  const handleExitMode = useCallback(() => {
    exitItemSelectionMode();
    // Also clear selection in REAPER
    sendCommand(itemCmd.unselectAll());
  }, [exitItemSelectionMode, sendCommand]);

  // Selection details sheet handlers
  const handleClearAll = useCallback(() => {
    sendCommand(itemCmd.unselectAll());
    setShowSelectionSheet(false);
  }, [sendCommand]);

  const handleDeselectItem = useCallback(
    (item: WSItem) => {
      sendCommand(itemCmd.toggleSelect(item.guid));
    },
    [sendCommand]
  );

  const toggleTrackExpanded = useCallback((trackIdx: number) => {
    setExpandedTracks((prev) => {
      const next = new Set(prev);
      if (next.has(trackIdx)) {
        next.delete(trackIdx);
      } else {
        next.add(trackIdx);
      }
      return next;
    });
  }, []);

  // Group selected items by track for details sheet
  const groupedByTrack = useMemo((): TrackGroup[] => {
    const groups = new Map<number, WSItem[]>();

    for (const item of selectedItems) {
      const existing = groups.get(item.trackIdx) ?? [];
      existing.push(item);
      groups.set(item.trackIdx, existing);
    }

    return Array.from(groups.entries())
      .sort(([a], [b]) => a - b)
      .map(([trackIdx, trackItems]) => ({
        trackIdx,
        trackName: trackSkeleton[trackIdx]?.n ?? `Track ${trackIdx + 1}`,
        items: trackItems.sort((a, b) => a.position - b.position),
        isExpanded: expandedTracks.has(trackIdx),
      }));
  }, [selectedItems, trackSkeleton, expandedTracks]);

  // Expand all tracks by default when sheet opens
  useEffect(() => {
    if (showSelectionSheet && expandedTracks.size === 0 && groupedByTrack.length > 0) {
      setExpandedTracks(new Set(groupedByTrack.map((g) => g.trackIdx)));
    }
  }, [showSelectionSheet, groupedByTrack, expandedTracks.size]);

  // Auto-close selection sheet if selection drops to 0
  useEffect(() => {
    if (showSelectionSheet && selectedCount === 0) {
      setShowSelectionSheet(false);
    }
  }, [showSelectionSheet, selectedCount]);

  // Auto-close batch sheet if selection drops below 2
  useEffect(() => {
    if (showBatchSheet && selectedCount < 2) {
      setShowBatchSheet(false);
    }
  }, [showBatchSheet, selectedCount]);

  // Don't render if not in item selection mode
  if (!itemSelectionModeActive) return null;

  // Format values for single item display
  const currentColor = singleItem?.color
    ? reaperColorToHexWithFallback(singleItem.color, DEFAULT_ITEM_COLOR)
    : DEFAULT_ITEM_COLOR;
  const takeCount = singleItem?.takeCount ?? 1;
  const formattedPosition = singleItem ? formatBeats(singleItem.position) : '-';

  return (
    <div data-testid="item-info-bar" className={`flex flex-col gap-1.5 px-3 py-2 bg-bg-surface/50 rounded-lg text-sm relative ${className}`}>
      {/* Close button (X) - top right */}
      <button
        onClick={handleExitMode}
        className="absolute top-1 right-1 p-1.5 rounded hover:bg-bg-hover text-text-muted hover:text-text-primary transition-colors z-10"
        title="Clear selection"
        data-testid="item-mode-close"
      >
        <X className="w-4 h-4" />
      </button>

      {/* Row 1: Selection pill + take name (when single item with take name) */}
      <div className="flex items-center gap-3 min-w-0 pr-8">
        {selectedCount > 0 && (
          <button
            onClick={() => setShowSelectionSheet(true)}
            className="flex items-center gap-1 px-2 py-0.5 rounded-full bg-primary/20 hover:bg-primary/30 text-primary text-xs font-medium transition-colors"
            title="View selected items"
            data-testid="selection-pill"
          >
            <span data-testid="selection-count">{selectedCount}</span> selected
            <ChevronRight className="w-3 h-3" />
          </button>
        )}
        {singleItem?.activeTakeName && (
          <span className="text-xs text-text-primary truncate" title={singleItem.activeTakeName}>
            {singleItem.activeTakeName}
          </span>
        )}
      </div>

      {/* Row 2: Content varies based on selection count */}
      {selectedCount === 0 ? (
        // No items selected - prompt to select
        <div className="text-xs text-text-muted py-1">
          Tap an item to select
        </div>
      ) : selectedCount === 1 && singleItem ? (
        // Single item selected - show full controls
        <div className="flex items-center gap-3">
          {/* Position */}
          <div className="flex items-center gap-1.5">
            <span className="text-text-secondary text-xs">At:</span>
            <span className="text-info-muted font-mono text-xs">
              {formattedPosition}
            </span>
          </div>

          <div className="w-px h-6 bg-bg-hover" />

          {/* Take navigation */}
          <div className="flex items-center gap-1.5">
            <button
              onClick={handlePrevTake}
              disabled={takeCount <= 1}
              className="p-2 rounded hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-not-allowed"
              title="Previous take"
            >
              <ChevronLeft className="w-4 h-4" />
            </button>
            <span className="text-xs text-text-secondary min-w-[55px] text-center">
              Take {singleItem.activeTakeIdx + 1}/{takeCount}
            </span>
            <button
              onClick={handleNextTake}
              disabled={takeCount <= 1}
              className="p-2 rounded hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-not-allowed"
              title="Next take"
            >
              <ChevronRight className="w-4 h-4" />
            </button>
          </div>

          <div className="w-px h-6 bg-bg-hover" />

          {/* Color picker */}
          <ColorPickerInput
            label=""
            value={currentColor}
            onChange={handleColorChange}
            defaultValue={DEFAULT_ITEM_COLOR}
            compact
          />

          {/* More button - opens item details bottom sheet */}
          <button
            onClick={() => setShowItemSheet(true)}
            className="p-1.5 rounded hover:bg-bg-elevated"
            title="More options"
          >
            <MoreHorizontal className="w-4 h-4" />
          </button>
        </div>
      ) : (
        // Multiple items selected - batch mode
        <div className="flex items-center gap-3">
          <span className="text-xs text-text-secondary">
            {groupedByTrack.length > 1
              ? `${selectedCount} items across ${groupedByTrack.length} tracks`
              : `${selectedCount} items on ${groupedByTrack[0]?.trackName ?? 'track'}`}
          </span>

          {/* Group button - opens batch operations sheet */}
          <button
            onClick={() => setShowBatchSheet(true)}
            className="ml-auto flex items-center gap-1.5 px-2.5 py-1 rounded bg-bg-elevated hover:bg-bg-hover text-text-primary text-xs transition-colors"
            title="Batch operations"
            data-testid="batch-actions-btn"
          >
            <Group className="w-4 h-4" />
            Actions
          </button>
        </div>
      )}

      {/* Single Item Details Bottom Sheet */}
      <BottomSheet
        isOpen={showItemSheet}
        onClose={() => setShowItemSheet(false)}
        ariaLabel="Item details"
      >
        {singleItem && (
          <div className="px-4 pb-6">
            {/* Header */}
            <div className="text-center mb-4 pt-1">
              <h2 className="text-lg font-semibold text-text-primary truncate">
                Item Details
              </h2>
              <p className="text-sm text-text-secondary">
                {getTrackNameFromSkeleton(singleItem.trackIdx) || `Track ${singleItem.trackIdx + 1}`}
              </p>
            </div>

            {/* Takes section - only show if multiple takes */}
            {singleItem.takeCount > 1 && (
              <div className="mb-4">
                <h3 className="text-xs font-medium text-text-muted uppercase mb-2">
                  Takes ({singleItem.takeCount})
                </h3>
                <div className="space-y-1 max-h-48 overflow-y-auto">
                  {Array.from({ length: singleItem.takeCount }, (_, i) => (
                    <button
                      key={i}
                      onClick={() => {
                        sendCommand(
                          itemCmd.setActiveTake(singleItem.trackIdx, singleItem.itemIdx, i)
                        );
                      }}
                      className={`w-full flex items-center gap-2 px-3 py-2 rounded-lg text-left text-sm transition-colors ${
                        i === singleItem.activeTakeIdx
                          ? 'bg-accent/20 text-text-primary'
                          : 'bg-bg-surface hover:bg-bg-hover text-text-secondary'
                      }`}
                    >
                      {i === singleItem.activeTakeIdx && (
                        <Check className="w-4 h-4 text-accent flex-shrink-0" />
                      )}
                      <div className={`flex flex-col ${i === singleItem.activeTakeIdx ? '' : 'ml-6'}`}>
                        <span>Take {i + 1}</span>
                        {i === singleItem.activeTakeIdx && singleItem.activeTakeName && (
                          <span className="text-xs text-text-muted truncate">
                            {singleItem.activeTakeName}
                          </span>
                        )}
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            )}

            {/* Actions section */}
            <div className="mb-4">
              <h3 className="text-xs font-medium text-text-muted uppercase mb-2">
                Actions
              </h3>
              <div className="flex flex-wrap gap-2">
                {/* Lock/Unlock */}
                <button
                  onClick={handleToggleLock}
                  className={`flex items-center gap-2 px-3 py-2 rounded-lg text-sm transition-colors ${
                    singleItem.locked
                      ? 'bg-warning/20 text-warning'
                      : 'bg-bg-surface hover:bg-bg-hover text-text-secondary'
                  }`}
                >
                  {singleItem.locked ? (
                    <Lock className="w-4 h-4" />
                  ) : (
                    <Unlock className="w-4 h-4" />
                  )}
                  {singleItem.locked ? 'Locked' : 'Unlocked'}
                </button>

                {/* Crop to active take */}
                {singleItem.takeCount > 1 && (
                  <button
                    onClick={handleCropToActive}
                    className="flex items-center gap-2 px-3 py-2 rounded-lg text-sm bg-bg-surface hover:bg-bg-hover text-text-secondary transition-colors"
                  >
                    <Scissors className="w-4 h-4" />
                    Crop to Take
                  </button>
                )}

                {/* Delete take */}
                {singleItem.takeCount > 1 && (
                  <button
                    onClick={handleDeleteTake}
                    className="flex items-center gap-2 px-3 py-2 rounded-lg text-sm bg-error-bg hover:bg-error/30 text-error-text transition-colors"
                  >
                    <Trash2 className="w-4 h-4" />
                    Delete Take
                  </button>
                )}
              </div>
            </div>

            {/* Notes section */}
            <div className="mb-4">
              <h3 className="text-xs font-medium text-text-muted uppercase mb-2">
                Notes
              </h3>
              {isEditingNotes ? (
                <div className="space-y-2">
                  <textarea
                    ref={notesInputRef}
                    value={notesValue}
                    onChange={(e) => setNotesValue(e.target.value)}
                    onKeyDown={handleNotesKeyDown}
                    placeholder="Add notes..."
                    className="w-full bg-bg-elevated text-text-primary text-base px-3 py-2 rounded-lg border border-border-default focus:border-accent focus:outline-none resize-none"
                    rows={3}
                  />
                  <div className="flex gap-2">
                    <button
                      onClick={handleNotesSubmit}
                      className="px-3 py-1.5 text-sm bg-primary text-on-primary rounded-lg hover:bg-primary-hover transition-colors"
                    >
                      Save
                    </button>
                    <button
                      onClick={() => setIsEditingNotes(false)}
                      className="px-3 py-1.5 text-sm text-text-secondary hover:text-text-primary transition-colors"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              ) : notesLoading ? (
                <div className="w-full bg-bg-elevated text-text-muted text-sm px-3 py-2 rounded-lg border border-border-default">
                  Loading...
                </div>
              ) : notesValue ? (
                <button
                  onClick={() => setIsEditingNotes(true)}
                  className="w-full text-left bg-bg-elevated text-text-primary text-sm px-3 py-2 rounded-lg border border-border-default hover:border-text-tertiary transition-colors"
                >
                  <span className="block truncate">{notesValue.split('\n')[0]}</span>
                  {notesValue.includes('\n') && (
                    <span className="text-text-muted text-xs">...</span>
                  )}
                </button>
              ) : (
                <button
                  onClick={() => setIsEditingNotes(true)}
                  className="w-full text-left bg-bg-elevated text-text-muted text-sm px-3 py-2 rounded-lg border border-border-default border-dashed hover:border-text-tertiary transition-colors"
                >
                  Add notes...
                </button>
              )}
            </div>

            {/* Color section */}
            <div className="mb-4">
              <ColorPickerInput
                label="Color"
                value={currentColor}
                onChange={handleColorChange}
                defaultValue={DEFAULT_ITEM_COLOR}
              />
            </div>

            {/* Item info - position and length */}
            <div className="mb-4">
              <h3 className="text-xs font-medium text-text-muted uppercase mb-2">
                Position & Length
              </h3>
              <div className="grid grid-cols-2 gap-3 text-sm">
                <div className="bg-bg-surface rounded-lg p-2">
                  <div className="text-text-muted text-xs mb-1">Position</div>
                  <div className="font-mono text-text-primary">{formattedPosition}</div>
                  <div className="font-mono text-text-secondary text-xs">{formatTime(singleItem.position)}</div>
                </div>
                <div className="bg-bg-surface rounded-lg p-2">
                  <div className="text-text-muted text-xs mb-1">Length</div>
                  <div className="font-mono text-text-primary">{formatDuration(singleItem.length)}</div>
                  <div className="font-mono text-text-secondary text-xs">{formatTime(singleItem.length)}</div>
                </div>
              </div>
            </div>

            {/* MIDI indicator */}
            {singleItem.activeTakeIsMidi && (
              <div className="text-sm text-info-muted bg-info-muted/10 rounded-lg px-3 py-2">
                MIDI Item
              </div>
            )}
          </div>
        )}
      </BottomSheet>

      {/* Batch Operations Bottom Sheet */}
      <BottomSheet
        isOpen={showBatchSheet}
        onClose={() => setShowBatchSheet(false)}
        ariaLabel="Batch operations"
      >
        <div className="px-4 pb-6">
          {/* Header */}
          <div className="text-center mb-4 pt-1">
            <h2 className="text-lg font-semibold text-text-primary">
              Batch Operations
            </h2>
            <p className="text-sm text-text-secondary">
              Apply to {selectedCount} selected items
            </p>
          </div>

          {/* Color section */}
          <div className="mb-4">
            <h3 className="text-xs font-medium text-text-muted uppercase mb-2 flex items-center gap-2">
              <Palette className="w-3 h-3" />
              Color All
            </h3>
            <ColorPickerInput
              label=""
              value={DEFAULT_ITEM_COLOR}
              onChange={handleBatchColorChange}
              defaultValue={DEFAULT_ITEM_COLOR}
            />
          </div>

          {/* Lock/Unlock section */}
          <div className="mb-4">
            <h3 className="text-xs font-medium text-text-muted uppercase mb-2 flex items-center gap-2">
              <Lock className="w-3 h-3" />
              Lock State
            </h3>
            <div className="flex gap-2">
              <button
                onClick={handleBatchLockAll}
                disabled={allLocked}
                className="flex-1 flex items-center justify-center gap-2 px-3 py-2.5 rounded-lg text-sm bg-bg-surface hover:bg-bg-hover text-text-secondary transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
              >
                <Lock className="w-4 h-4" />
                Lock All
              </button>
              <button
                onClick={handleBatchUnlockAll}
                disabled={!anyLocked}
                className="flex-1 flex items-center justify-center gap-2 px-3 py-2.5 rounded-lg text-sm bg-bg-surface hover:bg-bg-hover text-text-secondary transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
              >
                <Unlock className="w-4 h-4" />
                Unlock All
              </button>
            </div>
          </div>

          {/* Take navigation section - only if any items have multiple takes */}
          {anyHaveMultipleTakes && (
            <div className="mb-4">
              <h3 className="text-xs font-medium text-text-muted uppercase mb-2">
                Takes (items with multiple takes)
              </h3>
              <div className="flex gap-2">
                <button
                  onClick={handleBatchPrevTake}
                  className="flex-1 flex items-center justify-center gap-2 px-3 py-2.5 rounded-lg text-sm bg-bg-surface hover:bg-bg-hover text-text-secondary transition-colors"
                >
                  <ChevronLeft className="w-4 h-4" />
                  Prev Take
                </button>
                <button
                  onClick={handleBatchNextTake}
                  className="flex-1 flex items-center justify-center gap-2 px-3 py-2.5 rounded-lg text-sm bg-bg-surface hover:bg-bg-hover text-text-secondary transition-colors"
                >
                  Next Take
                  <ChevronRight className="w-4 h-4" />
                </button>
              </div>
            </div>
          )}
        </div>
      </BottomSheet>

      {/* Selection Details Bottom Sheet (opened by pill) */}
      <BottomSheet
        isOpen={showSelectionSheet}
        onClose={() => setShowSelectionSheet(false)}
        ariaLabel="Selected items"
      >
        <div className="px-4 pb-6 max-h-[70vh] overflow-y-auto">
          {/* Header */}
          <div className="text-center mb-4 pt-1">
            <h2 className="text-lg font-semibold text-text-primary">
              {selectedCount} Items Selected
            </h2>
            <p className="text-sm text-text-secondary">
              {groupedByTrack.length > 1 && `across ${groupedByTrack.length} tracks`}
            </p>
          </div>

          {/* Items grouped by track (accordions) */}
          <div className="space-y-2">
            {groupedByTrack.map((group) => (
              <div key={group.trackIdx} className="bg-bg-surface rounded-lg overflow-hidden">
                {/* Track header (accordion toggle) */}
                <button
                  onClick={() => toggleTrackExpanded(group.trackIdx)}
                  className="w-full flex items-center justify-between px-3 py-2 hover:bg-bg-hover transition-colors"
                >
                  <div className="flex items-center gap-2">
                    <span className="text-sm font-medium text-text-primary">
                      {group.trackName}
                    </span>
                    <span className="text-xs text-text-muted">
                      ({group.items.length})
                    </span>
                  </div>
                  {group.isExpanded ? (
                    <ChevronUp className="w-4 h-4 text-text-muted" />
                  ) : (
                    <ChevronDown className="w-4 h-4 text-text-muted" />
                  )}
                </button>

                {/* Items on this track (collapsible) */}
                {group.isExpanded && (
                  <div className="border-t border-border-subtle">
                    {group.items.map((item) => (
                      <button
                        key={item.guid}
                        onClick={() => handleDeselectItem(item)}
                        className="w-full flex items-center justify-between px-3 py-2 hover:bg-bg-hover text-left transition-colors group border-b border-border-subtle last:border-b-0"
                      >
                        <div className="flex-1 min-w-0">
                          <div className="text-sm text-text-primary truncate">
                            Item {item.itemIdx + 1}
                          </div>
                          <div className="text-xs text-text-muted font-mono">
                            {formatBeats(item.position)} · {formatDuration(item.length)}
                          </div>
                        </div>
                        <div className="ml-2 text-text-tertiary group-hover:text-text-secondary">
                          <X className="w-4 h-4" />
                        </div>
                      </button>
                    ))}
                  </div>
                )}
              </div>
            ))}
          </div>

          {/* Clear all button */}
          <button
            onClick={handleClearAll}
            className="w-full mt-4 px-4 py-3 rounded-lg bg-error-bg hover:bg-error/30 text-error-text text-sm font-medium transition-colors"
          >
            Clear Selection
          </button>
        </div>
      </BottomSheet>
    </div>
  );
}
