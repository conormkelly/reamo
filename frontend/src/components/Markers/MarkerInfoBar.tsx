/**
 * Marker Info Bar Component
 * Shows marker info in Navigate mode: ID, name, color, timestamp
 * Supports inline editing of name and color
 * Auto-advances to show the most recently passed marker during playback
 */

import { useState, useRef, useEffect, useCallback, type ReactElement } from 'react';
import { RotateCcw, X } from 'lucide-react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useCurrentMarker, useTimeFormatters } from '../../hooks';
import { marker as markerCmd } from '../../core/WebSocketCommands';
import { reaperColorToHex, hexToReaperColor } from '../../utils';
import { DEFAULT_MARKER_COLOR, MARKER_COLORS } from '../../constants/colors';

interface MarkerInfoBarProps {
  className?: string;
}

export function MarkerInfoBar({ className = '' }: MarkerInfoBarProps): ReactElement | null {
  const { sendCommand } = useReaper();
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const markers = useReaperStore((s) => s.markers);
  const setSelectedMarkerId = useReaperStore((s) => s.setSelectedMarkerId);

  const { currentMarker, setLocked } = useCurrentMarker();
  const { formatBeats } = useTimeFormatters();

  const [isEditingName, setIsEditingName] = useState(false);
  const [nameValue, setNameValue] = useState('');
  const [showColorPicker, setShowColorPicker] = useState(false);
  const [isSaving, setIsSaving] = useState(false);

  const nameInputRef = useRef<HTMLInputElement>(null);
  const colorPickerRef = useRef<HTMLDivElement>(null);
  const saveTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Focus name input when editing starts
  useEffect(() => {
    if (isEditingName && nameInputRef.current) {
      nameInputRef.current.focus();
      nameInputRef.current.select();
    }
  }, [isEditingName]);

  // Close color picker on outside click
  useEffect(() => {
    if (!showColorPicker) return;

    const handleClickOutside = (e: MouseEvent) => {
      if (colorPickerRef.current && !colorPickerRef.current.contains(e.target as Node)) {
        setShowColorPicker(false);
        setLocked(false);
      }
    };

    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showColorPicker, setLocked]);

  // Lock auto-advance when editing
  useEffect(() => {
    if (isEditingName || showColorPicker) {
      setLocked(true);
    }
  }, [isEditingName, showColorPicker, setLocked]);

  // Cleanup save timeout on unmount
  useEffect(() => {
    return () => {
      if (saveTimeoutRef.current) {
        clearTimeout(saveTimeoutRef.current);
      }
    };
  }, []);

  // Save marker name/color using native command
  const saveMarkerEdit = useCallback(
    (name: string, color: number) => {
      if (!currentMarker) return;

      setIsSaving(true);
      sendCommand(markerCmd.update(currentMarker.id, { name, color }));
      setIsSaving(false);
    },
    [currentMarker, sendCommand]
  );

  // Only show in navigate mode with a marker selected
  // IMPORTANT: This early return must come AFTER all hooks
  if (timelineMode !== 'navigate' || !currentMarker) {
    return null;
  }

  // Get colors from existing markers for picker
  const existingColors = new Set<string>();
  markers.forEach((m) => {
    if (m.color) {
      const hex = reaperColorToHex(m.color);
      if (hex) existingColors.add(hex);
    }
  });

  // Check if marker uses default color (color = 0 or undefined)
  const isDefaultColor = !currentMarker.color || currentMarker.color === 0;
  const currentColor = isDefaultColor
    ? DEFAULT_MARKER_COLOR
    : reaperColorToHex(currentMarker.color!) ?? DEFAULT_MARKER_COLOR;

  const handleNameClick = () => {
    if (!currentMarker) return;
    setNameValue(currentMarker.name);
    setIsEditingName(true);
  };

  const handleNameConfirm = () => {
    if (!currentMarker) {
      setIsEditingName(false);
      return;
    }

    const trimmedName = nameValue.trim();
    if (trimmedName && trimmedName !== currentMarker.name) {
      // Debounced save
      if (saveTimeoutRef.current) {
        clearTimeout(saveTimeoutRef.current);
      }
      saveTimeoutRef.current = setTimeout(() => {
        saveMarkerEdit(trimmedName, currentMarker.color ?? 0);
      }, 300);
    }

    setIsEditingName(false);
    setLocked(false);
  };

  const handleNameCancel = () => {
    setIsEditingName(false);
    setLocked(false);
  };

  const handleNameKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      handleNameConfirm();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      handleNameCancel();
    }
  };

  const handleColorClick = () => {
    if (!currentMarker) return;
    setShowColorPicker(true);
  };

  const handleColorSelect = (hex: string) => {
    if (!currentMarker) return;
    const reaperColor = hexToReaperColor(hex);
    saveMarkerEdit(currentMarker.name, reaperColor);
    setShowColorPicker(false);
    setLocked(false);
  };

  const handleColorReset = () => {
    if (!currentMarker) return;
    // Send 0 to reset to REAPER's default marker color
    saveMarkerEdit(currentMarker.name, 0);
    setShowColorPicker(false);
    setLocked(false);
  };

  // Format position as beats (hook handles fallback to time if no BPM)
  const formatPosition = (seconds: number): string => formatBeats(seconds);

  const handleClose = () => {
    setSelectedMarkerId(null);
  };

  return (
    <div data-testid="marker-info-bar" className={`flex items-center gap-2 min-w-0 ${className}`}>
      <div className="flex flex-col gap-1 px-3 py-1.5 bg-bg-surface/50 rounded-lg text-sm flex-1 min-w-0 relative">
        {/* X close button - top right */}
        <button
          onClick={handleClose}
          className="absolute top-1 right-1 p-1 text-text-muted hover:text-text-primary hover:bg-bg-elevated rounded transition-colors"
          title="Close marker info"
        >
          <X size={14} />
        </button>

        {/* Line 1: Marker ID and Name */}
        <div className="flex items-center gap-3 min-w-0">
          {/* Marker ID */}
          <div className="flex items-center gap-1.5">
            <span className="text-text-secondary text-xs">Marker:</span>
            <span className="text-text-primary font-mono text-xs font-bold">{currentMarker.id}</span>
          </div>

          <div className="w-px h-4 bg-border-default flex-shrink-0" />

          {/* Name (editable if script installed) */}
          <div className="flex items-center gap-1.5 flex-1 min-w-0">
            <span className="text-text-secondary text-xs flex-shrink-0">Name:</span>
            {isEditingName ? (
              <input
                ref={nameInputRef}
                type="text"
                value={nameValue}
                onChange={(e) => setNameValue(e.target.value)}
                onKeyDown={handleNameKeyDown}
                onBlur={handleNameConfirm}
                className="flex-1 min-w-0 px-1.5 py-0.5 bg-bg-elevated border border-focus-border rounded text-text-primary font-mono text-xs focus:outline-none focus:ring-1 focus:ring-focus-ring"
              />
            ) : (
              <button
                onClick={handleNameClick}
                className="text-text-primary font-mono text-xs px-1.5 py-0.5 rounded transition-colors truncate min-w-0 hover:bg-bg-elevated cursor-pointer"
                title="Click to edit name"
              >
                {currentMarker.name || '(unnamed)'}
              </button>
            )}
          </div>

          {/* Saving indicator */}
          {isSaving && (
            <span className="text-text-muted text-xs italic ml-auto">Saving...</span>
          )}
        </div>

        {/* Line 2: Color and Position */}
        <div className="flex items-center gap-3">
          {/* Color indicator */}
          <div className="flex items-center gap-1.5 relative">
            <span className="text-text-secondary text-xs">Color:</span>
            <button
              onClick={handleColorClick}
              className="w-6 h-6 rounded border-2 transition-colors border-border-default hover:border-text-secondary cursor-pointer"
              style={{ backgroundColor: currentColor }}
              title="Click to change color"
            />
            {showColorPicker && (
              <div
                ref={colorPickerRef}
                className="absolute top-full left-0 mt-2 p-3 bg-bg-surface border border-border-default rounded-lg shadow-xl z-50 min-w-[200px]"
              >
                {/* Default + Project colors row */}
                <div className="mb-3">
                  <div className="flex gap-2 overflow-x-auto pb-1 max-w-[200px] items-center">
                    {/* Default (reset) color - always first */}
                    <button
                      onClick={handleColorReset}
                      className={`w-6 h-6 rounded border-2 transition-all flex-shrink-0 relative ${
                        isDefaultColor
                          ? 'border-white scale-110'
                          : 'border-transparent hover:border-text-secondary'
                      }`}
                      style={{ backgroundColor: DEFAULT_MARKER_COLOR }}
                      title="Reset to default"
                    >
                      <RotateCcw size={10} className="absolute inset-0 m-auto text-white/80" />
                    </button>

                    {/* Existing colors from project */}
                    {Array.from(existingColors).map((color) => (
                      <button
                        key={color}
                        onClick={() => handleColorSelect(color)}
                        className={`w-6 h-6 rounded border-2 transition-all flex-shrink-0 ${
                          !isDefaultColor && currentColor.toLowerCase() === color.toLowerCase()
                            ? 'border-white scale-110'
                            : 'border-transparent hover:border-text-secondary'
                        }`}
                        style={{ backgroundColor: color }}
                      />
                    ))}
                  </div>
                </div>

                {/* Preset colors */}
                <div className="mb-3">
                  <div className="text-xs text-text-secondary mb-1.5">Presets</div>
                  <div className="flex gap-2 flex-wrap">
                    {MARKER_COLORS.map((color) => (
                      <button
                        key={color}
                        onClick={() => handleColorSelect(color)}
                        className={`w-6 h-6 rounded border-2 transition-all ${
                          !isDefaultColor && currentColor.toLowerCase() === color.toLowerCase()
                            ? 'border-white scale-110'
                            : 'border-transparent hover:border-text-secondary'
                        }`}
                        style={{ backgroundColor: color }}
                      />
                    ))}
                  </div>
                </div>

                {/* Color picker and hex input */}
                <div className="text-xs text-text-secondary mb-1.5">Custom</div>
                <div className="flex gap-2 items-center">
                  <input
                    type="color"
                    value={currentColor}
                    onChange={(e) => handleColorSelect(e.target.value)}
                    className="w-8 h-8 rounded border-2 border-border-default cursor-pointer bg-transparent"
                  />
                  <input
                    type="text"
                    placeholder="Default"
                    defaultValue={isDefaultColor ? '' : currentColor}
                    className="flex-1 px-2 py-1 bg-bg-elevated border border-border-default rounded text-text-primary text-xs font-mono focus:outline-none focus:border-focus-border"
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') {
                        const val = (e.target as HTMLInputElement).value;
                        if (/^#?[0-9a-f]{6}$/i.test(val)) {
                          handleColorSelect(val.startsWith('#') ? val : `#${val}`);
                        }
                      }
                    }}
                  />
                </div>
              </div>
            )}
          </div>

          <div className="w-px h-4 bg-border-default flex-shrink-0" />

          {/* Position - use server bar string if available */}
          <div className="flex items-center gap-1.5">
            <span className="text-text-secondary text-xs">At:</span>
            <span className="text-info-muted font-mono text-xs">
              {currentMarker.positionBars ?? formatPosition(currentMarker.position)}
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}
