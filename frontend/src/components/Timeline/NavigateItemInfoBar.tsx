/**
 * NavigateItemInfoBar Component
 * Shows item info in Navigate mode when an item is selected
 * Features: track selector dropdown, item navigation (prev/next),
 * take navigation, color picker, and "More" button for BottomSheet
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
  ChevronDown,
  MoreHorizontal,
  Check,
  Scissors,
  Trash2,
  Lock,
  Unlock,
} from 'lucide-react';
import { BottomSheet } from '../Modal/BottomSheet';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTimeFormatters, type UseViewportReturn } from '../../hooks';
import { item as itemCmd, take as takeCmd } from '../../core/WebSocketCommands';
import { hexToReaperColor, reaperColorToHexWithFallback, formatTime } from '../../utils';
import { DEFAULT_ITEM_COLOR } from '../../constants/colors';
import { ColorPickerInput } from '../Toolbar/ColorPickerInput';
import { EMPTY_SKELETON } from '../../store/stableRefs';
import type { SkeletonTrack } from '../../core/WebSocketTypes';
import { EMPTY_ITEMS } from '../../store/stableRefs';
import type { Track } from '../../core/types';

export interface NavigateItemInfoBarProps {
  className?: string;
  viewport: UseViewportReturn;
}

export function NavigateItemInfoBar({
  className = '',
  viewport,
}: NavigateItemInfoBarProps): ReactElement | null {
  const { sendCommand, sendAsync, connected } = useReaper();
  const { formatBeats, formatDuration } = useTimeFormatters();

  // Store state
  const items = useReaperStore((s) => s?.items ?? EMPTY_ITEMS);
  const tracks = useReaperStore((s) => s.tracks);
  const trackSkeleton = useReaperStore((s) => s?.trackSkeleton ?? EMPTY_SKELETON) as readonly SkeletonTrack[];
  const selectedItemGuid = useReaperStore((s) => s.selectedItemGuid);
  const selectItem = useReaperStore((s) => s.selectItem);

  // Local state for track selector and bottom sheet
  const [selectedTrackGuid, setSelectedTrackGuid] = useState<string | null>(null);
  const [showTrackDropdown, setShowTrackDropdown] = useState(false);
  const [showItemSheet, setShowItemSheet] = useState(false);
  const trackDropdownRef = useRef<HTMLDivElement>(null);

  // Notes state (fetched on-demand)
  const [isEditingNotes, setIsEditingNotes] = useState(false);
  const [notesValue, setNotesValue] = useState('');
  const [notesLoading, setNotesLoading] = useState(false);
  const notesInputRef = useRef<HTMLTextAreaElement>(null);

  // Find selected item by GUID
  const selectedItem = useMemo(() => {
    if (!selectedItemGuid) return null;
    return items.find((item) => item.guid === selectedItemGuid) ?? null;
  }, [selectedItemGuid, items]);

  // Get track from GUID
  const getTrackFromGuid = useCallback(
    (guid: string): Track | null => {
      return Object.values(tracks).find((t) => t.guid === guid) ?? null;
    },
    [tracks]
  );

  // Get track index from GUID
  const getTrackIdxFromGuid = useCallback(
    (guid: string): number | null => {
      const track = getTrackFromGuid(guid);
      return track?.index ?? null;
    },
    [getTrackFromGuid]
  );

  // Get tracks with items in viewport (for dropdown)
  const tracksWithItemsInViewport = useMemo(() => {
    const trackGuids = new Set<string>();
    items.forEach((item) => {
      const itemEnd = item.position + item.length;
      if (
        item.position < viewport.visibleRange.end &&
        itemEnd > viewport.visibleRange.start
      ) {
        const track = tracks[item.trackIdx];
        if (track?.guid) trackGuids.add(track.guid);
      }
    });
    // Sort by track index for consistent ordering
    return Array.from(trackGuids).sort((a, b) => {
      const trackA = getTrackFromGuid(a);
      const trackB = getTrackFromGuid(b);
      return (trackA?.index ?? 0) - (trackB?.index ?? 0);
    });
  }, [items, viewport.visibleRange, tracks, getTrackFromGuid]);

  // Default to selected item's track when item is selected
  useEffect(() => {
    if (selectedItem && !selectedTrackGuid) {
      const track = tracks[selectedItem.trackIdx];
      if (track?.guid) {
        setSelectedTrackGuid(track.guid);
      }
    }
  }, [selectedItem, selectedTrackGuid, tracks]);

  // Also update track when selected item changes to a different track
  useEffect(() => {
    if (selectedItem) {
      const track = tracks[selectedItem.trackIdx];
      if (track?.guid && track.guid !== selectedTrackGuid) {
        setSelectedTrackGuid(track.guid);
      }
    }
  }, [selectedItem, tracks, selectedTrackGuid]);

  // Get current track for display
  const currentTrack = useMemo(() => {
    if (!selectedTrackGuid) return null;
    return getTrackFromGuid(selectedTrackGuid);
  }, [selectedTrackGuid, getTrackFromGuid]);

  // Get items on selected track sorted by position
  // Use selectedItem.trackIdx as fallback if selectedTrackGuid not resolved
  const trackItems = useMemo(() => {
    let trackIdx: number | null = null;
    if (selectedTrackGuid) {
      trackIdx = getTrackIdxFromGuid(selectedTrackGuid);
    }
    // Fallback: use selectedItem's trackIdx directly
    if (trackIdx === null && selectedItem) {
      trackIdx = selectedItem.trackIdx;
    }
    if (trackIdx === null) return [];
    return items
      .filter((item) => item.trackIdx === trackIdx)
      .sort((a, b) => a.position - b.position);
  }, [items, selectedTrackGuid, getTrackIdxFromGuid, selectedItem]);

  // Find current item index in track items
  const currentItemIndex = useMemo(() => {
    if (!selectedItemGuid || trackItems.length === 0) return -1;
    return trackItems.findIndex((item) => item.guid === selectedItemGuid);
  }, [trackItems, selectedItemGuid]);

  // Move viewport to center on item if it's outside current viewport
  const moveViewportToItem = useCallback(
    (item: typeof selectedItem) => {
      if (!item) return;

      const itemStart = item.position;
      const itemEnd = item.position + item.length;
      const itemCenter = item.position + item.length / 2;
      const viewportDuration =
        viewport.visibleRange.end - viewport.visibleRange.start;

      // Only move if item is outside current viewport
      if (
        itemStart < viewport.visibleRange.start ||
        itemEnd > viewport.visibleRange.end
      ) {
        // Center viewport on item
        const newStart = Math.max(0, itemCenter - viewportDuration / 2);
        viewport.setVisibleRange({
          start: newStart,
          end: newStart + viewportDuration,
        });
      }
    },
    [viewport]
  );

  // Item navigation
  const handlePrevItem = useCallback(() => {
    if (currentItemIndex > 0) {
      const prevItem = trackItems[currentItemIndex - 1];
      selectItem(prevItem.guid);
      // Sync selection to REAPER so actions can be applied to this item
      sendCommand(itemCmd.select(prevItem.trackIdx, prevItem.itemIdx));
      moveViewportToItem(prevItem);
    }
  }, [currentItemIndex, trackItems, selectItem, sendCommand, moveViewportToItem]);

  const handleNextItem = useCallback(() => {
    if (currentItemIndex < trackItems.length - 1) {
      const nextItem = trackItems[currentItemIndex + 1];
      selectItem(nextItem.guid);
      // Sync selection to REAPER so actions can be applied to this item
      sendCommand(itemCmd.select(nextItem.trackIdx, nextItem.itemIdx));
      moveViewportToItem(nextItem);
    }
  }, [currentItemIndex, trackItems, selectItem, sendCommand, moveViewportToItem]);

  // Take navigation
  const handlePrevTake = useCallback(() => {
    if (!selectedItem || selectedItem.activeTakeIdx <= 0) return;
    sendCommand(
      itemCmd.setActiveTake(selectedItem.trackIdx, selectedItem.itemIdx, selectedItem.activeTakeIdx - 1)
    );
  }, [selectedItem, sendCommand]);

  const handleNextTake = useCallback(() => {
    if (!selectedItem || selectedItem.activeTakeIdx >= selectedItem.takeCount - 1) return;
    sendCommand(
      itemCmd.setActiveTake(selectedItem.trackIdx, selectedItem.itemIdx, selectedItem.activeTakeIdx + 1)
    );
  }, [selectedItem, sendCommand]);

  // Track change handler
  const handleTrackChange = useCallback(
    (newTrackGuid: string) => {
      setSelectedTrackGuid(newTrackGuid);
      setShowTrackDropdown(false);

      const trackIdx = getTrackIdxFromGuid(newTrackGuid);
      if (trackIdx === null) return;

      // Find first item on this track in viewport (or first item if none in viewport)
      const trackItemsForNewTrack = items
        .filter((item) => item.trackIdx === trackIdx)
        .sort((a, b) => a.position - b.position);

      const itemInViewport = trackItemsForNewTrack.find((item) => {
        const itemEnd = item.position + item.length;
        return (
          item.position < viewport.visibleRange.end &&
          itemEnd > viewport.visibleRange.start
        );
      });

      const itemToSelect = itemInViewport ?? trackItemsForNewTrack[0];
      if (itemToSelect) {
        selectItem(itemToSelect.guid);
        // Sync to REAPER
        sendCommand(itemCmd.select(itemToSelect.trackIdx, itemToSelect.itemIdx));
        moveViewportToItem(itemToSelect);
      }
    },
    [getTrackIdxFromGuid, items, viewport.visibleRange, selectItem, sendCommand, moveViewportToItem]
  );

  // Get track name from skeleton (always available, unlike tracks)
  const getTrackNameFromSkeleton = useCallback(
    (trackIdx: number): string | null => {
      return trackSkeleton[trackIdx]?.n ?? null;
    },
    [trackSkeleton]
  );

  // Color picker handler
  const handleColorChange = useCallback(
    (color: string) => {
      if (!selectedItem) return;
      const reaperColor = hexToReaperColor(color);
      sendCommand(
        itemCmd.setColor(selectedItem.trackIdx, selectedItem.itemIdx, reaperColor)
      );
    },
    [selectedItem, sendCommand]
  );

  // Item action handlers
  const handleCropToActive = useCallback(() => {
    sendCommand(takeCmd.cropToActive());
  }, [sendCommand]);

  const handleDeleteTake = useCallback(() => {
    if (selectedItem && selectedItem.takeCount > 1) {
      sendCommand(takeCmd.delete());
    }
  }, [selectedItem, sendCommand]);

  const handleToggleLock = useCallback(() => {
    if (!selectedItem) return;
    sendCommand(itemCmd.setLock(selectedItem.trackIdx, selectedItem.itemIdx, selectedItem.locked ? 0 : 1));
  }, [selectedItem, sendCommand]);

  // Notes handlers
  const handleNotesSubmit = useCallback(() => {
    if (!selectedItem) return;
    sendCommand(itemCmd.setNotes(selectedItem.trackIdx, selectedItem.itemIdx, notesValue));
    setIsEditingNotes(false);
  }, [selectedItem, sendCommand, notesValue]);

  const handleNotesKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (e.key === 'Escape') {
      setIsEditingNotes(false);
    }
  }, []);

  // Reset notes when item changes
  useEffect(() => {
    setNotesValue('');
    setIsEditingNotes(false);
  }, [selectedItemGuid]);

  // Fetch notes when sheet opens (if item has notes)
  useEffect(() => {
    if (!showItemSheet || !selectedItem?.hasNotes || !connected) return;
    if (notesValue) return; // Already fetched

    const fetchNotes = async () => {
      setNotesLoading(true);
      try {
        const cmd = itemCmd.getNotes(selectedItem.trackIdx, selectedItem.itemIdx);
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
  }, [showItemSheet, selectedItem, connected, sendAsync, notesValue]);

  // Focus notes input when editing starts
  useEffect(() => {
    if (isEditingNotes && !notesLoading && notesInputRef.current) {
      notesInputRef.current.focus();
    }
  }, [isEditingNotes, notesLoading]);

  // Close dropdowns on outside click
  useEffect(() => {
    if (!showTrackDropdown) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (
        trackDropdownRef.current &&
        !trackDropdownRef.current.contains(e.target as Node)
      ) {
        setShowTrackDropdown(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showTrackDropdown]);

  // Don't render if no item selected
  if (!selectedItem) return null;

  // Format values
  const currentColor = selectedItem.color
    ? reaperColorToHexWithFallback(selectedItem.color, DEFAULT_ITEM_COLOR)
    : DEFAULT_ITEM_COLOR;
  const takeCount = selectedItem.takeCount;
  const formattedPosition = formatBeats(selectedItem.position);

  return (
    <div data-testid="item-info-bar" className={`flex flex-col gap-1 px-3 py-1.5 bg-bg-surface/50 rounded-lg text-sm ${className}`}>
      {/* Row 1: Track dropdown | Position */}
      <div className="flex items-center gap-3 min-w-0">
        {/* Track selector dropdown */}
        <div className="relative" ref={trackDropdownRef}>
          <button
            onClick={() => setShowTrackDropdown(!showTrackDropdown)}
            className="flex items-center gap-1 px-2 py-0.5 rounded bg-bg-elevated hover:bg-bg-hover text-text-primary text-xs"
          >
            <span className="truncate max-w-[120px]">
              {getTrackNameFromSkeleton(selectedItem?.trackIdx ?? -1) || currentTrack?.name || `Track ${currentTrack?.index ?? selectedItem?.trackIdx ?? '?'}`}
            </span>
            <ChevronDown className="w-3 h-3 flex-shrink-0" />
          </button>
          {showTrackDropdown && tracksWithItemsInViewport.length > 0 && (
            <div className="absolute top-full left-0 mt-1 py-1 bg-bg-elevated border border-border-default rounded-lg shadow-xl z-50 min-w-[150px] max-h-[200px] overflow-y-auto">
              {tracksWithItemsInViewport.map((guid) => {
                const track = getTrackFromGuid(guid);
                if (!track) return null;
                return (
                  <button
                    key={guid}
                    onClick={() => handleTrackChange(guid)}
                    className={`w-full text-left px-3 py-1.5 text-xs hover:bg-bg-hover ${
                      guid === selectedTrackGuid
                        ? 'bg-bg-hover text-text-primary'
                        : 'text-text-secondary'
                    }`}
                  >
                    {track.name || `Track ${track.index}`}
                  </button>
                );
              })}
            </div>
          )}
        </div>

        <div className="w-px h-4 bg-border-default flex-shrink-0" />

        {/* Position */}
        <div className="flex items-center gap-1.5">
          <span className="text-text-secondary text-xs">At:</span>
          <span className="text-info-muted font-mono text-xs">
            {formattedPosition}
          </span>
        </div>
      </div>

      {/* Row 2: Item nav | Take nav | Color | More */}
      <div className="flex items-center gap-3">
        {/* Item navigation */}
        <div className="flex items-center gap-1">
          <button
            onClick={handlePrevItem}
            disabled={currentItemIndex <= 0}
            className="p-1 rounded hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-not-allowed"
            title="Previous item on track"
          >
            <ChevronLeft className="w-4 h-4" />
          </button>
          <span className="text-sm text-text-primary min-w-[50px] text-center">
            {currentItemIndex >= 0 ? currentItemIndex + 1 : '-'}/{trackItems.length}
          </span>
          <button
            onClick={handleNextItem}
            disabled={currentItemIndex >= trackItems.length - 1}
            className="p-1 rounded hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-not-allowed"
            title="Next item on track"
          >
            <ChevronRight className="w-4 h-4" />
          </button>
        </div>

        <div className="w-px h-6 bg-bg-hover" />

        {/* Take navigation */}
        <div className="flex items-center gap-1">
          <button
            onClick={handlePrevTake}
            disabled={takeCount <= 1}
            className="p-1 rounded hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-not-allowed"
            title="Previous take"
          >
            <ChevronLeft className="w-3 h-3" />
          </button>
          <span className="text-xs text-text-secondary min-w-[55px] text-center">
            Take {selectedItem.activeTakeIdx + 1}/{takeCount}
          </span>
          <button
            onClick={handleNextTake}
            disabled={takeCount <= 1}
            className="p-1 rounded hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-not-allowed"
            title="Next take"
          >
            <ChevronRight className="w-3 h-3" />
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

      {/* Item Details Bottom Sheet */}
      <BottomSheet
        isOpen={showItemSheet}
        onClose={() => setShowItemSheet(false)}
        ariaLabel="Item details"
      >
        <div className="px-4 pb-6">
          {/* Header */}
          <div className="text-center mb-4 pt-1">
            <h2 className="text-lg font-semibold text-text-primary truncate">
              Item {currentItemIndex + 1} of {trackItems.length}
            </h2>
            <p className="text-sm text-text-secondary">
              {getTrackNameFromSkeleton(selectedItem.trackIdx) || `Track ${selectedItem.trackIdx + 1}`}
            </p>
          </div>

          {/* Takes section - only show if multiple takes */}
          {selectedItem.takeCount > 1 && (
            <div className="mb-4">
              <h3 className="text-xs font-medium text-text-muted uppercase mb-2">
                Takes ({selectedItem.takeCount})
              </h3>
              <div className="space-y-1 max-h-48 overflow-y-auto">
                {Array.from({ length: selectedItem.takeCount }, (_, i) => (
                  <button
                    key={i}
                    onClick={() => {
                      sendCommand(
                        itemCmd.setActiveTake(selectedItem.trackIdx, selectedItem.itemIdx, i)
                      );
                    }}
                    className={`w-full flex items-center gap-2 px-3 py-2 rounded-lg text-left text-sm transition-colors ${
                      i === selectedItem.activeTakeIdx
                        ? 'bg-accent/20 text-text-primary'
                        : 'bg-bg-surface hover:bg-bg-hover text-text-secondary'
                    }`}
                  >
                    {i === selectedItem.activeTakeIdx && (
                      <Check className="w-4 h-4 text-accent flex-shrink-0" />
                    )}
                    <span className={i === selectedItem.activeTakeIdx ? '' : 'ml-6'}>
                      Take {i + 1}
                    </span>
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
                  selectedItem.locked
                    ? 'bg-warning/20 text-warning'
                    : 'bg-bg-surface hover:bg-bg-hover text-text-secondary'
                }`}
              >
                {selectedItem.locked ? (
                  <Lock className="w-4 h-4" />
                ) : (
                  <Unlock className="w-4 h-4" />
                )}
                {selectedItem.locked ? 'Locked' : 'Unlocked'}
              </button>

              {/* Crop to active take */}
              {selectedItem.takeCount > 1 && (
                <button
                  onClick={handleCropToActive}
                  className="flex items-center gap-2 px-3 py-2 rounded-lg text-sm bg-bg-surface hover:bg-bg-hover text-text-secondary transition-colors"
                >
                  <Scissors className="w-4 h-4" />
                  Crop to Take
                </button>
              )}

              {/* Delete take */}
              {selectedItem.takeCount > 1 && (
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
              /* Editing mode - full textarea */
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
              /* Loading state */
              <div className="w-full bg-bg-elevated text-text-muted text-sm px-3 py-2 rounded-lg border border-border-default">
                Loading...
              </div>
            ) : notesValue ? (
              /* Preview mode - show first line with ellipsis */
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
              /* Empty state - add notes button styled as empty textarea */
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

          {/* Item info - position and length in bars and seconds */}
          <div className="mb-4">
            <h3 className="text-xs font-medium text-text-muted uppercase mb-2">
              Position & Length
            </h3>
            <div className="grid grid-cols-2 gap-3 text-sm">
              <div className="bg-bg-surface rounded-lg p-2">
                <div className="text-text-muted text-xs mb-1">Position</div>
                <div className="font-mono text-text-primary">{formattedPosition}</div>
                <div className="font-mono text-text-secondary text-xs">{formatTime(selectedItem.position)}</div>
              </div>
              <div className="bg-bg-surface rounded-lg p-2">
                <div className="text-text-muted text-xs mb-1">Length</div>
                <div className="font-mono text-text-primary">{formatDuration(selectedItem.length)}</div>
                <div className="font-mono text-text-secondary text-xs">{formatTime(selectedItem.length)}</div>
              </div>
            </div>
          </div>

          {/* MIDI indicator */}
          {selectedItem.activeTakeIsMidi && (
            <div className="text-sm text-info-muted bg-info-muted/10 rounded-lg px-3 py-2">
              MIDI Item
            </div>
          )}
        </div>
      </BottomSheet>
    </div>
  );
}
