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
} from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useTimeFormatters, type UseViewportReturn } from '../../hooks';
import { item as itemCmd } from '../../core/WebSocketCommands';
import { parseItemKey } from '../../store/slices/itemsSlice';
import { hexToReaperColor, reaperColorToHexWithFallback } from '../../utils';
import { DEFAULT_ITEM_COLOR, ITEM_COLORS } from '../../constants/colors';
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
  const { sendCommand } = useReaper();
  const { formatBeats } = useTimeFormatters();

  // Store state
  const items = useReaperStore((s) => s?.items ?? EMPTY_ITEMS);
  const tracks = useReaperStore((s) => s.tracks);
  const selectedItemKey = useReaperStore((s) => s.selectedItemKey);
  const selectItem = useReaperStore((s) => s.selectItem);

  // Local state for track selector and color picker
  const [selectedTrackGuid, setSelectedTrackGuid] = useState<string | null>(null);
  const [showColorPicker, setShowColorPicker] = useState(false);
  const [showTrackDropdown, setShowTrackDropdown] = useState(false);
  const colorPickerRef = useRef<HTMLDivElement>(null);
  const trackDropdownRef = useRef<HTMLDivElement>(null);

  // Parse selected item
  const selectedItem = useMemo(() => {
    if (!selectedItemKey) return null;
    const parsed = parseItemKey(selectedItemKey);
    if (!parsed) return null;
    return items.find(
      (item) =>
        item.trackIdx === parsed.trackIdx && item.itemIdx === parsed.itemIdx
    ) ?? null;
  }, [selectedItemKey, items]);

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
  const trackItems = useMemo(() => {
    if (!selectedTrackGuid) return [];
    const trackIdx = getTrackIdxFromGuid(selectedTrackGuid);
    if (trackIdx === null) return [];
    return items
      .filter((item) => item.trackIdx === trackIdx)
      .sort((a, b) => a.position - b.position);
  }, [items, selectedTrackGuid, getTrackIdxFromGuid]);

  // Find current item index in track items
  const currentItemIndex = useMemo(() => {
    if (!selectedItemKey || trackItems.length === 0) return -1;
    return trackItems.findIndex(
      (item) => `${item.trackIdx}:${item.itemIdx}` === selectedItemKey
    );
  }, [trackItems, selectedItemKey]);

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
      selectItem(prevItem.trackIdx, prevItem.itemIdx);
      moveViewportToItem(prevItem);
    }
  }, [currentItemIndex, trackItems, selectItem, moveViewportToItem]);

  const handleNextItem = useCallback(() => {
    if (currentItemIndex < trackItems.length - 1) {
      const nextItem = trackItems[currentItemIndex + 1];
      selectItem(nextItem.trackIdx, nextItem.itemIdx);
      moveViewportToItem(nextItem);
    }
  }, [currentItemIndex, trackItems, selectItem, moveViewportToItem]);

  // Take navigation (using GUID-based command for stability)
  const handlePrevTake = useCallback(() => {
    if (!selectedItem || selectedItem.activeTakeIdx <= 0) return;
    const track = tracks[selectedItem.trackIdx];
    if (!track?.guid) return;
    sendCommand(
      itemCmd.setActiveTakeByGuid(track.guid, selectedItem.guid, selectedItem.activeTakeIdx - 1)
    );
  }, [selectedItem, tracks, sendCommand]);

  const handleNextTake = useCallback(() => {
    if (!selectedItem || selectedItem.activeTakeIdx >= selectedItem.takeCount - 1) return;
    const track = tracks[selectedItem.trackIdx];
    if (!track?.guid) return;
    sendCommand(
      itemCmd.setActiveTakeByGuid(track.guid, selectedItem.guid, selectedItem.activeTakeIdx + 1)
    );
  }, [selectedItem, tracks, sendCommand]);

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
        selectItem(itemToSelect.trackIdx, itemToSelect.itemIdx);
        moveViewportToItem(itemToSelect);
      }
    },
    [getTrackIdxFromGuid, items, viewport.visibleRange, selectItem, moveViewportToItem]
  );

  // Color picker handlers
  const handleColorChange = useCallback(
    (color: string) => {
      if (!selectedItem) return;
      const reaperColor = hexToReaperColor(color);
      sendCommand(
        itemCmd.setColor(selectedItem.trackIdx, selectedItem.itemIdx, reaperColor)
      );
      setShowColorPicker(false);
    },
    [selectedItem, sendCommand]
  );

  // Close dropdowns on outside click
  useEffect(() => {
    if (!showColorPicker && !showTrackDropdown) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (
        colorPickerRef.current &&
        !colorPickerRef.current.contains(e.target as Node)
      ) {
        setShowColorPicker(false);
      }
      if (
        trackDropdownRef.current &&
        !trackDropdownRef.current.contains(e.target as Node)
      ) {
        setShowTrackDropdown(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showColorPicker, showTrackDropdown]);

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
              {currentTrack?.name || `Track ${currentTrack?.index ?? '?'}`}
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
        <div className="relative" ref={colorPickerRef}>
          <button
            onClick={() => setShowColorPicker(!showColorPicker)}
            className="w-6 h-6 rounded border-2 transition-colors border-border-default hover:border-text-secondary cursor-pointer"
            style={{ backgroundColor: currentColor }}
            title="Set color"
          />
          {showColorPicker && (
            <div className="absolute bottom-full right-0 mb-2 p-2 bg-bg-elevated rounded-lg shadow-lg z-50">
              <div className="grid grid-cols-4 gap-1">
                {ITEM_COLORS.map((color) => (
                  <button
                    key={color}
                    onClick={() => handleColorChange(color)}
                    className="w-6 h-6 rounded border border-border-default hover:scale-110 transition-transform"
                    style={{ backgroundColor: color }}
                  />
                ))}
              </div>
              <input
                type="color"
                value={currentColor}
                onChange={(e) => handleColorChange(e.target.value)}
                className="w-full h-6 mt-2 rounded cursor-pointer"
              />
            </div>
          )}
        </div>

        {/* More button (placeholder for BottomSheet) */}
        <button
          onClick={() => {
            // TODO: Open ItemDetailsBottomSheet
            console.log('Open item details bottom sheet');
          }}
          className="p-1.5 rounded hover:bg-bg-elevated"
          title="More options"
        >
          <MoreHorizontal className="w-4 h-4" />
        </button>
      </div>
    </div>
  );
}
