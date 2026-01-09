/**
 * ItemInfoBar Component
 * Shows take info, actions, and metadata when an item is selected
 *
 * Note: Uses sparse fields from WSItem. Full notes/takes are fetched on-demand.
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { ChevronLeft, ChevronRight, Scissors, Trash2, Lock, Unlock, Palette } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { take as takeCmd, item as itemCmd } from '../../core/WebSocketCommands';
import type { WSItem } from '../../core/WebSocketTypes';
import { hexToReaperColor, reaperColorToHexWithFallback } from '../../utils';
import { DEFAULT_ITEM_COLOR, ITEM_COLORS } from '../../constants/colors';

interface ItemInfoBarProps {
  item: WSItem;
  className?: string;
}

export function ItemInfoBar({ item, className = '' }: ItemInfoBarProps): ReactElement {
  const { sendCommand, connection } = useReaper();
  // Use sparse fields from WSItem (full data fetched on-demand)
  const takeCount = item.takeCount;

  // State for color picker
  const [showColorPicker, setShowColorPicker] = useState(false);
  const colorPickerRef = useRef<HTMLDivElement>(null);

  // State for notes editing (fetched on-demand when editing starts)
  const [isEditingNotes, setIsEditingNotes] = useState(false);
  const [notesValue, setNotesValue] = useState('');
  const [notesLoading, setNotesLoading] = useState(false);
  const notesInputRef = useRef<HTMLInputElement>(null);

  // Close color picker when clicking outside
  useEffect(() => {
    if (!showColorPicker) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (colorPickerRef.current && !colorPickerRef.current.contains(e.target as Node)) {
        setShowColorPicker(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showColorPicker]);

  // Focus notes input when editing starts
  useEffect(() => {
    if (isEditingNotes && notesInputRef.current) {
      notesInputRef.current.focus();
      notesInputRef.current.select();
    }
  }, [isEditingNotes]);

  // Reset notes when item changes (will be fetched on-demand)
  useEffect(() => {
    setNotesValue('');
    setIsEditingNotes(false);
  }, [item.guid]);

  // Fetch notes on-demand when editing starts
  const handleStartEditingNotes = async () => {
    if (!connection) return;
    setIsEditingNotes(true);
    setNotesLoading(true);
    try {
      const cmd = itemCmd.getNotes(item.trackIdx, item.itemIdx);
      const response = await connection.sendAsync(cmd.command, cmd.params) as {
        success: boolean;
        payload?: { notes: string };
      };
      if (response.success && response.payload) {
        setNotesValue(response.payload.notes || '');
      }
    } catch {
      // Failed to fetch, allow editing with empty string
      setNotesValue('');
    } finally {
      setNotesLoading(false);
    }
  };

  // Take navigation
  const handlePrevTake = () => {
    sendCommand(takeCmd.prev());
  };

  const handleNextTake = () => {
    sendCommand(takeCmd.next());
  };

  // Take actions
  const handleCropToActive = () => {
    sendCommand(takeCmd.cropToActive());
  };

  const handleDeleteTake = () => {
    if (takeCount > 1) {
      sendCommand(takeCmd.delete());
    }
  };

  // Item actions
  const handleToggleLock = () => {
    sendCommand(itemCmd.setLock(item.trackIdx, item.itemIdx, item.locked ? 0 : 1));
  };

  const handleColorChange = (color: string) => {
    const reaperColor = hexToReaperColor(color);
    sendCommand(itemCmd.setColor(item.trackIdx, item.itemIdx, reaperColor));
    setShowColorPicker(false);
  };

  const handleNotesSubmit = () => {
    sendCommand(itemCmd.setNotes(item.trackIdx, item.itemIdx, notesValue));
    setIsEditingNotes(false);
  };

  const handleNotesKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      handleNotesSubmit();
    } else if (e.key === 'Escape') {
      // Cancel editing - value will be re-fetched next time
      setIsEditingNotes(false);
    }
  };

  // Current color
  const currentColor = item.color
    ? reaperColorToHexWithFallback(item.color, DEFAULT_ITEM_COLOR)
    : DEFAULT_ITEM_COLOR;


  return (
    <div className={`flex items-center gap-2 px-3 py-2 bg-bg-surface border-t border-border-subtle ${className}`}>
      {/* Take navigation */}
      <div className="flex items-center gap-1">
        <button
          onClick={handlePrevTake}
          disabled={takeCount <= 1}
          className="p-1 rounded hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-not-allowed"
          title="Previous take"
        >
          <ChevronLeft className="w-4 h-4" />
        </button>
        <span className="text-sm text-white min-w-[60px] text-center">
          Take {item.activeTakeIdx + 1}/{takeCount}
        </span>
        <button
          onClick={handleNextTake}
          disabled={takeCount <= 1}
          className="p-1 rounded hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-not-allowed"
          title="Next take"
        >
          <ChevronRight className="w-4 h-4" />
        </button>
      </div>

      {/* Divider */}
      <div className="w-px h-6 bg-bg-hover" />

      {/* Take info (sparse - name not available without fetch) */}
      <div className="flex-1 min-w-0">
        <span className="text-sm text-text-tertiary truncate block">
          Active Take
        </span>
      </div>

      {/* MIDI indicator (from sparse field) */}
      {item.activeTakeIsMidi && (
        <span className="text-xs bg-midi-badge text-white px-1.5 py-0.5 rounded">
          MIDI
        </span>
      )}

      {/* Notes (fetched on-demand when editing) */}
      <div className="flex items-center gap-1 min-w-[100px]">
        {isEditingNotes ? (
          notesLoading ? (
            <span className="text-sm text-text-muted">Loading...</span>
          ) : (
            <input
              ref={notesInputRef}
              type="text"
              value={notesValue}
              onChange={(e) => setNotesValue(e.target.value)}
              onBlur={handleNotesSubmit}
              onKeyDown={handleNotesKeyDown}
              className="w-full bg-bg-elevated text-text-primary text-sm px-2 py-0.5 rounded border border-border-default focus:border-accent-region focus:outline-none"
              placeholder="Add notes..."
            />
          )
        ) : (
          <button
            onClick={handleStartEditingNotes}
            className="text-sm text-text-secondary hover:text-text-primary truncate text-left"
            title={item.hasNotes ? 'Edit notes' : 'Add notes'}
          >
            {item.hasNotes ? 'Notes...' : 'Add notes...'}
          </button>
        )}
      </div>

      {/* Divider */}
      <div className="w-px h-6 bg-bg-hover" />

      {/* Actions */}
      <div className="flex items-center gap-1">
        {/* Color picker */}
        <div className="relative" ref={colorPickerRef}>
          <button
            onClick={() => setShowColorPicker(!showColorPicker)}
            className="p-1.5 rounded hover:bg-bg-elevated"
            title="Set color"
          >
            <Palette className="w-4 h-4" style={{ color: currentColor }} />
          </button>
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

        {/* Lock toggle */}
        <button
          onClick={handleToggleLock}
          className={`p-1.5 rounded hover:bg-bg-elevated ${item.locked ? 'text-locked' : ''}`}
          title={item.locked ? 'Unlock item' : 'Lock item'}
        >
          {item.locked ? <Lock className="w-4 h-4" /> : <Unlock className="w-4 h-4" />}
        </button>

        {/* Crop to active */}
        <button
          onClick={handleCropToActive}
          disabled={takeCount <= 1}
          className="p-1.5 rounded hover:bg-bg-elevated disabled:opacity-30 disabled:cursor-not-allowed"
          title="Crop to active take"
        >
          <Scissors className="w-4 h-4" />
        </button>

        {/* Delete take */}
        <button
          onClick={handleDeleteTake}
          disabled={takeCount <= 1}
          className="p-1.5 rounded hover:bg-bg-elevated text-error-text disabled:opacity-30 disabled:cursor-not-allowed"
          title="Delete active take"
        >
          <Trash2 className="w-4 h-4" />
        </button>
      </div>
    </div>
  );
}
