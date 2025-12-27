/**
 * ItemInfoBar Component
 * Shows take info, actions, and metadata when an item is selected
 */

import { useState, useRef, useEffect, type ReactElement } from 'react';
import { ChevronLeft, ChevronRight, Scissors, Trash2, Lock, Unlock, Palette } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { take as takeCmd, item as itemCmd } from '../../core/WebSocketCommands';
import type { WSItem } from '../../core/WebSocketTypes';
import { hexToReaperColor, reaperColorToHexWithFallback } from '../../utils';

// Default item color (gray)
const DEFAULT_ITEM_COLOR = '#646464';

interface ItemInfoBarProps {
  item: WSItem;
  className?: string;
}

export function ItemInfoBar({ item, className = '' }: ItemInfoBarProps): ReactElement {
  const { sendCommand } = useReaper();
  const activeTake = item.takes[item.activeTakeIdx];
  const takeCount = item.takes.length;

  // State for color picker
  const [showColorPicker, setShowColorPicker] = useState(false);
  const colorPickerRef = useRef<HTMLDivElement>(null);

  // State for notes editing
  const [isEditingNotes, setIsEditingNotes] = useState(false);
  const [notesValue, setNotesValue] = useState(item.notes);
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

  // Update notes value when item changes
  useEffect(() => {
    setNotesValue(item.notes);
  }, [item.notes]);

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
      setNotesValue(item.notes);
      setIsEditingNotes(false);
    }
  };

  // Current color
  const currentColor = item.color
    ? reaperColorToHexWithFallback(item.color, DEFAULT_ITEM_COLOR)
    : DEFAULT_ITEM_COLOR;

  // Preset colors for quick selection
  const presetColors = [
    '#FF6B6B', '#FFE66D', '#4ECDC4', '#45B7D1',
    '#96CEB4', '#FFEAA7', '#DDA0DD', '#98D8C8',
    '#F7DC6F', '#BB8FCE', '#85C1E9', '#F8B500',
  ];

  return (
    <div className={`flex items-center gap-2 px-3 py-2 bg-gray-800 border-t border-gray-700 ${className}`}>
      {/* Take navigation */}
      <div className="flex items-center gap-1">
        <button
          onClick={handlePrevTake}
          disabled={takeCount <= 1}
          className="p-1 rounded hover:bg-gray-700 disabled:opacity-30 disabled:cursor-not-allowed"
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
          className="p-1 rounded hover:bg-gray-700 disabled:opacity-30 disabled:cursor-not-allowed"
          title="Next take"
        >
          <ChevronRight className="w-4 h-4" />
        </button>
      </div>

      {/* Divider */}
      <div className="w-px h-6 bg-gray-600" />

      {/* Take name */}
      <div className="flex-1 min-w-0">
        <span className="text-sm text-gray-300 truncate block" title={activeTake?.name}>
          {activeTake?.name || 'Untitled'}
        </span>
      </div>

      {/* MIDI indicator */}
      {activeTake?.isMIDI && (
        <span className="text-xs bg-blue-600 text-white px-1.5 py-0.5 rounded">
          MIDI
        </span>
      )}

      {/* Notes */}
      <div className="flex items-center gap-1 min-w-[100px]">
        {isEditingNotes ? (
          <input
            ref={notesInputRef}
            type="text"
            value={notesValue}
            onChange={(e) => setNotesValue(e.target.value)}
            onBlur={handleNotesSubmit}
            onKeyDown={handleNotesKeyDown}
            className="w-full bg-gray-700 text-white text-sm px-2 py-0.5 rounded border border-gray-600 focus:border-purple-400 focus:outline-none"
            placeholder="Add notes..."
          />
        ) : (
          <button
            onClick={() => setIsEditingNotes(true)}
            className="text-sm text-gray-400 hover:text-white truncate text-left"
            title={item.notes || 'Add notes'}
          >
            {item.notes || 'Notes...'}
          </button>
        )}
      </div>

      {/* Divider */}
      <div className="w-px h-6 bg-gray-600" />

      {/* Actions */}
      <div className="flex items-center gap-1">
        {/* Color picker */}
        <div className="relative" ref={colorPickerRef}>
          <button
            onClick={() => setShowColorPicker(!showColorPicker)}
            className="p-1.5 rounded hover:bg-gray-700"
            title="Set color"
          >
            <Palette className="w-4 h-4" style={{ color: currentColor }} />
          </button>
          {showColorPicker && (
            <div className="absolute bottom-full right-0 mb-2 p-2 bg-gray-700 rounded-lg shadow-lg z-50">
              <div className="grid grid-cols-4 gap-1">
                {presetColors.map((color) => (
                  <button
                    key={color}
                    onClick={() => handleColorChange(color)}
                    className="w-6 h-6 rounded border border-gray-600 hover:scale-110 transition-transform"
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
          className={`p-1.5 rounded hover:bg-gray-700 ${item.locked ? 'text-yellow-400' : ''}`}
          title={item.locked ? 'Unlock item' : 'Lock item'}
        >
          {item.locked ? <Lock className="w-4 h-4" /> : <Unlock className="w-4 h-4" />}
        </button>

        {/* Crop to active */}
        <button
          onClick={handleCropToActive}
          disabled={takeCount <= 1}
          className="p-1.5 rounded hover:bg-gray-700 disabled:opacity-30 disabled:cursor-not-allowed"
          title="Crop to active take"
        >
          <Scissors className="w-4 h-4" />
        </button>

        {/* Delete take */}
        <button
          onClick={handleDeleteTake}
          disabled={takeCount <= 1}
          className="p-1.5 rounded hover:bg-gray-700 text-red-400 disabled:opacity-30 disabled:cursor-not-allowed"
          title="Delete active take"
        >
          <Trash2 className="w-4 h-4" />
        </button>
      </div>
    </div>
  );
}
