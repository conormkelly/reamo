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
 * Note: Track filter dropdown was removed — items are now visible across all
 * tracks in multi-track lanes, so single-track filtering is unnecessary.
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
  Move,
} from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTimeFormatters } from '../../hooks';
import { item as itemCmd, take as takeCmd } from '../../core/WebSocketCommands';
import {
  hexToReaperColor,
  reaperColorToHexWithFallback,
  formatTime,
  secondsToBeats,
  beatsToSeconds,
  formatBeatsToBarBeatTicks,
  parseBarBeatTicksToBeats,
} from '../../utils';
import { DEFAULT_ITEM_COLOR } from '../../constants/colors';
import { ColorPickerInput } from '../Toolbar/ColorPickerInput';
import { TrackPicker } from '../Mixer/RoutingModal/TrackPicker';
import { EMPTY_SKELETON, EMPTY_ITEMS } from '../../store/stableRefs';
import type { SkeletonTrack, WSItem } from '../../core/WebSocketTypes';

export interface NavigateItemInfoBarProps {
  className?: string;
  /** Layout mode - 'horizontal' for SecondaryPanel, 'vertical' for ContextRail */
  layout?: 'horizontal' | 'vertical';
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
  layout = 'horizontal',
}: NavigateItemInfoBarProps): ReactElement | null {
  const { sendCommand, sendAsync, connected } = useReaper();
  const { formatBeats, formatDuration, bpm, beatsPerBar, denominator, barOffset } = useTimeFormatters();

  // Store state
  const items = useReaperStore((s) => s?.items ?? EMPTY_ITEMS);
  const trackSkeleton = useReaperStore((s) => s?.trackSkeleton ?? EMPTY_SKELETON) as readonly SkeletonTrack[];
  const itemSelectionModeActive = useReaperStore((s) => s.itemSelectionModeActive);

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

  // Move item state
  const [showMoveUI, setShowMoveUI] = useState(false);
  const [showTrackPicker, setShowTrackPicker] = useState(false);
  const [moveEditMode, setMoveEditMode] = useState<'time' | 'beats'>('beats');
  const [moveTimeValue, setMoveTimeValue] = useState('');
  const [moveBeatsValue, setMoveBeatsValue] = useState('');
  const [movePosError, setMovePosError] = useState<string | null>(null);

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
    if (!singleItem || singleItem.takeCount <= 1) return;
    const prevIdx = singleItem.activeTakeIdx <= 0
      ? singleItem.takeCount - 1
      : singleItem.activeTakeIdx - 1;
    sendCommand(
      itemCmd.setActiveTake(singleItem.trackIdx, singleItem.itemIdx, prevIdx)
    );
  }, [singleItem, sendCommand]);

  const handleNextTake = useCallback(() => {
    if (!singleItem || singleItem.takeCount <= 1) return;
    const nextIdx = singleItem.activeTakeIdx >= singleItem.takeCount - 1
      ? 0
      : singleItem.activeTakeIdx + 1;
    sendCommand(
      itemCmd.setActiveTake(singleItem.trackIdx, singleItem.itemIdx, nextIdx)
    );
  }, [singleItem, sendCommand]);

  // Info bar color picker: always colors the active take
  const handleTakeColorChange = useCallback(
    (color: string) => {
      if (!singleItem) return;
      const reaperColor = hexToReaperColor(color);
      sendCommand(
        takeCmd.setColor(
          singleItem.trackIdx,
          singleItem.itemIdx,
          singleItem.activeTakeIdx,
          reaperColor
        )
      );
    },
    [singleItem, sendCommand]
  );

  // Bottom sheet color picker: always colors the item
  const handleItemColorChange = useCallback(
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

  // ========== Move Item Handlers ==========

  // Compute nudge amounts in seconds from BPM
  const beatDurationSeconds = bpm ? 60 / bpm : 0.5;
  const barDurationSeconds = beatDurationSeconds * beatsPerBar;

  // Parse time string (MM:SS.ms or SS.ms) to seconds
  const parseTime = useCallback((timeStr: string): number | null => {
    const trimmed = timeStr.trim();
    const colonMatch = trimmed.match(/^(\d+):(\d+(?:\.\d*)?)$/);
    if (colonMatch) {
      const mins = parseInt(colonMatch[1], 10);
      const secs = parseFloat(colonMatch[2]);
      return mins * 60 + secs;
    }
    const num = parseFloat(trimmed);
    if (!isNaN(num) && num >= 0) return num;
    return null;
  }, []);

  // Initialize move values when move UI opens or position changes
  const singleItemPosition = singleItem?.position ?? null;
  useEffect(() => {
    if (showMoveUI && singleItemPosition !== null && bpm) {
      setMoveTimeValue(formatTime(singleItemPosition, { precision: 3 }));
      const quarterNoteBeats = secondsToBeats(singleItemPosition, bpm);
      const denominatorBeats = quarterNoteBeats * (denominator / 4);
      setMoveBeatsValue(formatBeatsToBarBeatTicks(denominatorBeats, beatsPerBar, true, barOffset));
      setMovePosError(null);
    }
  }, [showMoveUI, singleItemPosition, bpm, beatsPerBar, denominator, barOffset]);

  // Reset move UI when item changes or sheet closes
  useEffect(() => {
    setShowMoveUI(false);
    setShowTrackPicker(false);
  }, [singleItem?.guid]);

  useEffect(() => {
    if (!showItemSheet) {
      setShowMoveUI(false);
      setShowTrackPicker(false);
    }
  }, [showItemSheet]);

  // Set position from input
  const handleSetPosition = useCallback(() => {
    if (!singleItem) return;
    let newPositionSeconds: number | null = null;

    if (moveEditMode === 'time') {
      newPositionSeconds = parseTime(moveTimeValue);
    } else {
      const denominatorBeats = parseBarBeatTicksToBeats(moveBeatsValue, beatsPerBar, barOffset);
      if (denominatorBeats !== null) {
        const quarterNoteBeats = denominatorBeats * (4 / denominator);
        const beats = quarterNoteBeats >= 0 ? quarterNoteBeats : 0;
        newPositionSeconds = beatsToSeconds(beats, bpm!);
      }
    }

    if (newPositionSeconds === null || newPositionSeconds < 0) {
      setMovePosError('Invalid position');
      return;
    }

    setMovePosError(null);
    sendCommand(itemCmd.moveByGuid(singleItem.guid, newPositionSeconds));
  }, [singleItem, moveEditMode, moveTimeValue, moveBeatsValue, bpm, beatsPerBar, denominator, barOffset, sendCommand, parseTime]);

  // Nudge position by delta seconds
  const handleNudge = useCallback(
    (deltaSeconds: number) => {
      if (!singleItem) return;
      const newPos = Math.max(0, singleItem.position + deltaSeconds);
      sendCommand(itemCmd.moveByGuid(singleItem.guid, newPos));
    },
    [singleItem, sendCommand]
  );

  // Move item to a different track
  const handleMoveToTrack = useCallback(
    (trackGuid: string) => {
      if (!singleItem) return;
      sendCommand(itemCmd.moveByGuid(singleItem.guid, undefined, trackGuid));
      setShowTrackPicker(false);
    },
    [singleItem, sendCommand]
  );

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

  // Context-aware coloring: show take color when multiple takes, otherwise item color
  // Take color for info bar swatch: take color if set, else item color (matches REAPER's render priority)
  const currentTakeColor = useMemo(() => {
    if (!singleItem) return DEFAULT_ITEM_COLOR;
    if (singleItem.activeTakeColor) {
      return reaperColorToHexWithFallback(singleItem.activeTakeColor, DEFAULT_ITEM_COLOR);
    }
    return reaperColorToHexWithFallback(singleItem.color, DEFAULT_ITEM_COLOR);
  }, [singleItem]);

  // Item color for bottom sheet
  const currentItemColor = useMemo(() => {
    if (!singleItem) return DEFAULT_ITEM_COLOR;
    return reaperColorToHexWithFallback(singleItem.color, DEFAULT_ITEM_COLOR);
  }, [singleItem]);

  // ========== Common Handlers ==========

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
      // eslint-disable-next-line no-restricted-syntax -- mutable array built inside useMemo
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
  const takeCount = singleItem?.takeCount ?? 1;
  const formattedPosition = singleItem ? formatBeats(singleItem.position) : '-';

  // --- Shared sub-components ---

  const selectionPill = selectedCount > 0 ? (
    <button
      onClick={() => setShowSelectionSheet(true)}
      className="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-primary/20 hover:bg-primary/30 text-primary text-sm font-medium transition-colors"
      title="View selected items"
      data-testid="selection-pill"
    >
      <span data-testid="selection-count">{selectedCount}</span> {selectedCount === 1 ? 'item' : 'items'}
      <ChevronRight className="w-3.5 h-3.5" />
    </button>
  ) : null;

  const takeNav = (
    <div className="flex items-center gap-1.5">
      <button
        onClick={handlePrevTake}
        disabled={takeCount <= 1}
        className="p-2 rounded hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-not-allowed"
        title="Previous take"
      >
        <ChevronLeft className="w-4 h-4" />
      </button>
      <span className="text-sm text-text-secondary min-w-[60px] text-center">
        Take {singleItem ? `${singleItem.activeTakeIdx + 1}/${takeCount}` : '-'}
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
  );

  const colorPicker = (
    <ColorPickerInput
      label=""
      value={currentTakeColor}
      onChange={handleTakeColorChange}
      defaultValue={DEFAULT_ITEM_COLOR}
      compact
    />
  );

  const moreButton = (
    <button
      onClick={() => setShowItemSheet(true)}
      className="p-1.5 rounded hover:bg-bg-elevated"
      title="More options"
    >
      <MoreHorizontal className="w-5 h-5" />
    </button>
  );

  // --- Bottom sheets (shared between layouts, rendered via portal) ---
  const bottomSheets = (
    <>
      {/* Single Item Details Bottom Sheet */}
      <BottomSheet
        isOpen={showItemSheet}
        onClose={() => setShowItemSheet(false)}
        ariaLabel="Item details"
      >
        {singleItem && (
          <div className="px-sheet-x pb-sheet-bottom">
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

            {/* Item color section */}
            <div className="mb-4">
              <ColorPickerInput
                label="Item Color"
                value={currentItemColor}
                onChange={handleItemColorChange}
                defaultValue={DEFAULT_ITEM_COLOR}
              />
            </div>

            {/* Item info - position and length */}
            <div className="mb-4">
              <h3 className="text-xs font-medium text-text-muted uppercase mb-2">
                Position & Length
              </h3>
              <div className="grid grid-cols-2 gap-3 text-sm">
                {/* Position - tappable to enter move mode */}
                <button
                  onClick={() => setShowMoveUI(!showMoveUI)}
                  className="bg-bg-surface rounded-lg p-2 text-left hover:ring-1 hover:ring-accent-primary/50 transition-all"
                >
                  <div className="text-text-muted text-xs mb-1 flex items-center gap-1">
                    Position
                    <Move className="w-3 h-3 opacity-50" />
                  </div>
                  <div className="font-mono text-text-primary">{formattedPosition}</div>
                  <div className="font-mono text-text-secondary text-xs">{formatTime(singleItem.position)}</div>
                </button>
                {/* Length - read-only */}
                <div className="bg-bg-surface rounded-lg p-2">
                  <div className="text-text-muted text-xs mb-1">Length</div>
                  <div className="font-mono text-text-primary">{formatDuration(singleItem.length)}</div>
                  <div className="font-mono text-text-secondary text-xs">{formatTime(singleItem.length)}</div>
                </div>
              </div>

              {/* Move UI - shown when position is tapped */}
              {showMoveUI && !showTrackPicker && (
                <div className="mt-3 space-y-3">
                  {/* Time / Bar.Beat toggle */}
                  <div className="flex rounded-lg overflow-hidden border border-border-default">
                    <button
                      onClick={() => setMoveEditMode('time')}
                      className={`flex-1 px-3 py-1.5 text-sm font-medium transition-colors ${
                        moveEditMode === 'time'
                          ? 'bg-primary text-text-on-primary'
                          : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                      }`}
                    >
                      Time
                    </button>
                    <button
                      onClick={() => setMoveEditMode('beats')}
                      className={`flex-1 px-3 py-1.5 text-sm font-medium transition-colors ${
                        moveEditMode === 'beats'
                          ? 'bg-primary text-text-on-primary'
                          : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                      }`}
                    >
                      Bar.Beat
                    </button>
                  </div>

                  {/* Position input */}
                  <input
                    type="text"
                    value={moveEditMode === 'time' ? moveTimeValue : moveBeatsValue}
                    onChange={(e) =>
                      moveEditMode === 'time'
                        ? setMoveTimeValue(e.target.value)
                        : setMoveBeatsValue(e.target.value)
                    }
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') handleSetPosition();
                    }}
                    className="w-full px-3 py-2 bg-bg-deep border border-border-default rounded text-text-primary text-sm font-mono focus:outline-none focus:border-focus-border"
                    placeholder={moveEditMode === 'time' ? 'MM:SS.ms (e.g. 1:30.000)' : 'Bar.Beat.Ticks (e.g. 5.3.00)'}
                  />

                  {/* Error message */}
                  {movePosError && <p className="text-error-text text-xs">{movePosError}</p>}

                  {/* Set Position button */}
                  <button
                    onClick={handleSetPosition}
                    className="w-full flex items-center justify-center gap-2 px-4 py-2 rounded font-medium transition-colors bg-primary hover:bg-primary-hover text-text-on-primary text-sm"
                  >
                    <Move size={14} />
                    Set Position
                  </button>

                  {/* Nudge buttons */}
                  <div className="flex gap-1 justify-center flex-wrap">
                    <button onClick={() => handleNudge(-barDurationSeconds)} className="px-2 py-1.5 rounded-md bg-bg-elevated text-text-secondary text-xs font-mono hover:bg-bg-surface active:bg-accent-primary/20 transition-colors">-1 bar</button>
                    <button onClick={() => handleNudge(-beatDurationSeconds)} className="px-2 py-1.5 rounded-md bg-bg-elevated text-text-secondary text-xs font-mono hover:bg-bg-surface active:bg-accent-primary/20 transition-colors">-1 beat</button>
                    <button onClick={() => handleNudge(-0.1)} className="px-2 py-1.5 rounded-md bg-bg-elevated text-text-secondary text-xs font-mono hover:bg-bg-surface active:bg-accent-primary/20 transition-colors">-0.1s</button>
                    <button onClick={() => handleNudge(0.1)} className="px-2 py-1.5 rounded-md bg-bg-elevated text-text-secondary text-xs font-mono hover:bg-bg-surface active:bg-accent-primary/20 transition-colors">+0.1s</button>
                    <button onClick={() => handleNudge(beatDurationSeconds)} className="px-2 py-1.5 rounded-md bg-bg-elevated text-text-secondary text-xs font-mono hover:bg-bg-surface active:bg-accent-primary/20 transition-colors">+1 beat</button>
                    <button onClick={() => handleNudge(barDurationSeconds)} className="px-2 py-1.5 rounded-md bg-bg-elevated text-text-secondary text-xs font-mono hover:bg-bg-surface active:bg-accent-primary/20 transition-colors">+1 bar</button>
                  </div>

                  {/* Move to track (hidden if only 1 user track) */}
                  {trackSkeleton.length > 2 && (
                    <button
                      onClick={() => setShowTrackPicker(true)}
                      className="w-full flex items-center justify-between px-3 py-2 rounded-lg bg-bg-surface hover:bg-bg-elevated text-sm transition-colors"
                    >
                      <span className="text-text-muted">Track</span>
                      <span className="text-text-primary">
                        {getTrackNameFromSkeleton(singleItem.trackIdx) || `Track ${singleItem.trackIdx}`}
                      </span>
                    </button>
                  )}
                </div>
              )}

              {/* Track picker (replaces move UI when active) */}
              {showMoveUI && showTrackPicker && (
                <div className="mt-3">
                  <TrackPicker
                    onSelect={handleMoveToTrack}
                    onCancel={() => setShowTrackPicker(false)}
                    excludeGuid={trackSkeleton[singleItem.trackIdx]?.g ?? ''}
                    prompt="Move to track"
                  />
                </div>
              )}
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
        <div className="px-sheet-x pb-sheet-bottom">
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
        <div className="px-sheet-x pb-sheet-bottom max-h-[70vh] overflow-y-auto">
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
    </>
  );

  // --- Vertical layout (landscape sidebar) ---
  if (layout === 'vertical') {
    return (
      <div data-testid="item-info-bar" className={`flex flex-col gap-2 px-3 py-2 text-sm ${className}`}>
        {/* Row 1: selection pill */}
        <div className="flex items-center gap-2 min-w-0">
          {selectionPill}
        </div>

        {selectedCount === 0 ? (
          <div className="text-sm text-text-muted py-1">
            Tap a marker pill or item
          </div>
        ) : selectedCount === 1 && singleItem ? (
          <>
            {/* Take name (own row) */}
            {singleItem.activeTakeName && (
              <span className="text-sm text-text-primary truncate" title={singleItem.activeTakeName}>
                {singleItem.activeTakeName}
              </span>
            )}

            {/* Position */}
            <span className="text-text-secondary font-mono text-xs">
              {formattedPosition}
            </span>

            {/* Take nav + color + more (compact row) */}
            <div className="flex items-center gap-2">
              {takeNav}
            </div>
            <div className="flex items-center gap-2">
              {colorPicker}
              {moreButton}
            </div>
          </>
        ) : (
          <>
            {/* Multi-select info */}
            <span className="text-sm text-text-secondary">
              {groupedByTrack.length > 1
                ? `${selectedCount} items across ${groupedByTrack.length} tracks`
                : `${selectedCount} items on ${groupedByTrack[0]?.trackName ?? 'track'}`}
            </span>

            {/* Batch actions button */}
            <button
              onClick={() => setShowBatchSheet(true)}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded bg-bg-elevated hover:bg-bg-hover text-text-primary text-sm transition-colors w-fit"
              title="Batch operations"
              data-testid="batch-actions-btn"
            >
              <Group className="w-4 h-4" />
              Actions
            </button>
          </>
        )}

        {/* Bottom sheets */}
        {bottomSheets}
      </div>
    );
  }

  // --- Horizontal layout (portrait SecondaryPanel) ---
  return (
    <div data-testid="item-info-bar" className={`flex flex-col gap-2 px-3 py-2 text-sm ${className}`}>
      {/* Row 1: Selection pill + take name */}
      <div className="flex items-center gap-3 min-w-0">
        {selectionPill}
        {singleItem?.activeTakeName && (
          <span className="text-sm text-text-primary truncate" title={singleItem.activeTakeName}>
            {singleItem.activeTakeName}
          </span>
        )}
      </div>

      {/* Row 2: Content varies based on selection count */}
      {selectedCount === 0 ? (
        <div className="text-sm text-text-muted py-1">
          Tap a marker pill or item
        </div>
      ) : selectedCount === 1 && singleItem ? (
        <div className="flex items-center gap-3">
          {takeNav}
          <div className="w-px h-6 bg-border-default flex-shrink-0" />
          {colorPicker}
          {moreButton}
        </div>
      ) : (
        <div className="flex items-center gap-3">
          <span className="text-sm text-text-secondary">
            {groupedByTrack.length > 1
              ? `${selectedCount} items across ${groupedByTrack.length} tracks`
              : `${selectedCount} items on ${groupedByTrack[0]?.trackName ?? 'track'}`}
          </span>
          <button
            onClick={() => setShowBatchSheet(true)}
            className="ml-auto flex items-center gap-1.5 px-3 py-1.5 rounded bg-bg-elevated hover:bg-bg-hover text-text-primary text-sm transition-colors"
            title="Batch operations"
            data-testid="batch-actions-btn"
          >
            <Group className="w-4 h-4" />
            Actions
          </button>
        </div>
      )}

      {/* Bottom sheets */}
      {bottomSheets}
    </div>
  );
}

