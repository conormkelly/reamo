/**
 * Marker Info Bar Component
 *
 * Layout matches TrackInfoBar for visual consistency.
 *
 * Horizontal (portrait SecondaryPanel):
 *   Marker: 3 | Name: Chorus
 *   Color: [●] | 4.1
 *
 * Vertical (landscape sidebar):
 *   Marker: 3
 *   Name: Chorus
 *   Color: [●]
 *   4.1
 *
 * Color: tap swatch = OS color picker, hold = reset to default.
 * Name: tap to edit inline.
 * Auto-advances to show the most recently passed marker during playback.
 */

import { useState, useRef, useEffect, useCallback, type ReactElement } from 'react';
import { useReaperStore } from '../../store';
import { useReaper } from '../ReaperProvider';
import { useCurrentMarker, useTimeFormatters } from '../../hooks';
import { marker as markerCmd } from '../../core/WebSocketCommands';
import { reaperColorToHex, hexToReaperColor, formatTime } from '../../utils';
import { DEFAULT_MARKER_COLOR } from '../../constants/colors';

interface MarkerInfoBarProps {
  className?: string;
  /** Layout mode - 'horizontal' for SecondaryPanel, 'vertical' for ContextRail */
  layout?: 'horizontal' | 'vertical';
}

const COLOR_HOLD_DURATION = 500;

export function MarkerInfoBar({ className = '', layout = 'horizontal' }: MarkerInfoBarProps): ReactElement | null {
  const { sendCommand } = useReaper();
  const timelineMode = useReaperStore((s) => s.timelineMode);
  const { currentMarker, setLocked } = useCurrentMarker();
  const { formatBeats } = useTimeFormatters();

  const [isEditingName, setIsEditingName] = useState(false);
  const [nameValue, setNameValue] = useState('');

  const nameInputRef = useRef<HTMLInputElement>(null);
  const saveTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Color swatch: tap = OS picker, hold = reset
  const colorInputRef = useRef<HTMLInputElement>(null);
  const colorHoldTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const colorDidResetRef = useRef(false);

  // Focus name input when editing starts
  useEffect(() => {
    if (isEditingName && nameInputRef.current) {
      nameInputRef.current.focus();
      nameInputRef.current.select();
    }
  }, [isEditingName]);

  // Lock auto-advance when editing name
  useEffect(() => {
    if (isEditingName) setLocked(true);
  }, [isEditingName, setLocked]);

  // Cleanup timers on unmount
  useEffect(() => {
    return () => {
      if (saveTimeoutRef.current) clearTimeout(saveTimeoutRef.current);
      if (colorHoldTimerRef.current) clearTimeout(colorHoldTimerRef.current);
    };
  }, []);

  // Save marker name/color using native command
  const saveMarkerEdit = useCallback(
    (name: string, color: number) => {
      if (!currentMarker) return;
      sendCommand(markerCmd.update(currentMarker.id, { name, color }));
    },
    [currentMarker, sendCommand]
  );

  // Only show in navigate mode with a marker selected
  // IMPORTANT: This early return must come AFTER all hooks
  if (timelineMode !== 'navigate' || !currentMarker) {
    return null;
  }

  const isDefaultColor = !currentMarker.color || currentMarker.color === 0;
  const currentColor = isDefaultColor
    ? DEFAULT_MARKER_COLOR
    : reaperColorToHex(currentMarker.color!) ?? DEFAULT_MARKER_COLOR;

  const positionDisplay = (currentMarker.positionBars ?? formatBeats(currentMarker.position)).replace(/\.00$/, '');

  // --- Name editing ---

  const handleNameClick = () => {
    setNameValue(currentMarker.name);
    setIsEditingName(true);
  };

  const handleNameConfirm = () => {
    const trimmedName = nameValue.trim();
    if (trimmedName && trimmedName !== currentMarker.name) {
      if (saveTimeoutRef.current) clearTimeout(saveTimeoutRef.current);
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
    if (e.key === 'Enter') { e.preventDefault(); handleNameConfirm(); }
    else if (e.key === 'Escape') { e.preventDefault(); handleNameCancel(); }
  };

  // --- Color swatch: tap = OS picker, hold = reset ---

  const handleColorPointerDown = () => {
    colorDidResetRef.current = false;
    colorHoldTimerRef.current = setTimeout(() => {
      colorDidResetRef.current = true;
      saveMarkerEdit(currentMarker.name, 0);
    }, COLOR_HOLD_DURATION);
  };

  const handleColorPointerUp = () => {
    if (colorHoldTimerRef.current) { clearTimeout(colorHoldTimerRef.current); colorHoldTimerRef.current = null; }
    if (!colorDidResetRef.current) colorInputRef.current?.click();
  };

  const handleColorPointerCancel = () => {
    if (colorHoldTimerRef.current) { clearTimeout(colorHoldTimerRef.current); colorHoldTimerRef.current = null; }
  };

  const handleColorChange = (hex: string) => {
    saveMarkerEdit(currentMarker.name, hexToReaperColor(hex));
  };

  // --- Shared sub-components ---

  const colorSwatch = (
    <div
      onPointerDown={handleColorPointerDown}
      onPointerUp={handleColorPointerUp}
      onPointerLeave={handleColorPointerCancel}
      onPointerCancel={handleColorPointerCancel}
      className="relative w-6 h-6 rounded-full border border-border-default cursor-pointer flex-shrink-0 touch-none"
      style={{ backgroundColor: currentColor }}
      title={isDefaultColor ? 'Tap to pick color' : 'Tap to change, hold to reset'}
    >
      {!isDefaultColor && (
        <div className="absolute -top-0.5 -right-0.5 w-2 h-2 bg-primary-hover rounded-full" />
      )}
      <input
        ref={colorInputRef}
        type="color"
        value={currentColor}
        onChange={(e) => handleColorChange(e.target.value)}
        className="absolute inset-0 opacity-0 cursor-pointer"
        tabIndex={-1}
      />
    </div>
  );

  const markerLabel = (
    <div className="flex items-center gap-1.5">
      <span className="text-text-secondary text-xs">Marker:</span>
      <span className="text-text-primary font-mono text-xs font-bold">{currentMarker.id}</span>
    </div>
  );

  const nameField = isEditingName ? (
    <input
      ref={nameInputRef}
      type="text"
      value={nameValue}
      onChange={(e) => setNameValue(e.target.value)}
      onKeyDown={handleNameKeyDown}
      onBlur={handleNameConfirm}
      className="flex-1 min-w-0 px-1.5 py-0.5 bg-bg-elevated border border-focus-border rounded text-text-primary text-base focus:outline-none focus:ring-1 focus:ring-focus-ring"
    />
  ) : (
    <button
      onClick={handleNameClick}
      className="text-text-primary text-sm truncate min-w-0 text-left px-1 py-0.5 rounded hover:bg-bg-elevated transition-colors"
    >
      {currentMarker.name || '(unnamed)'}
    </button>
  );

  // --- Vertical layout (landscape sidebar) ---
  if (layout === 'vertical') {
    return (
      <div data-testid="marker-info-bar" className={`flex flex-col gap-3 px-3 py-2 text-sm ${className}`}>
        {/* Marker: # */}
        {markerLabel}

        {/* Name: ... */}
        <div className="flex items-center gap-1.5 min-w-0">
          <span className="text-text-secondary text-xs flex-shrink-0">Name:</span>
          {nameField}
        </div>

        {/* Color: [●] */}
        <div className="flex items-center gap-1.5">
          <span className="text-text-secondary text-xs flex-shrink-0">Color:</span>
          {colorSwatch}
        </div>

        {/* position (bar.beat / time) */}
        <div className="flex items-center gap-1.5">
          <span className="text-text-primary font-mono text-xs">{positionDisplay}</span>
          <span className="text-text-muted font-mono text-xs">/ {formatTime(currentMarker.position)}</span>
        </div>
      </div>
    );
  }

  // --- Horizontal layout (portrait SecondaryPanel) ---
  return (
    <div data-testid="marker-info-bar" className={`flex flex-col gap-3 px-3 py-2 text-sm ${className}`}>
      {/* Row 1: Marker: # | Name: ... */}
      <div className="flex items-center gap-3 min-w-0">
        {markerLabel}

        <div className="w-px h-4 bg-border-default flex-shrink-0" />

        <div className="flex items-center gap-1.5 flex-1 min-w-0">
          <span className="text-text-secondary text-xs flex-shrink-0">Name:</span>
          {nameField}
        </div>
      </div>

      {/* Row 2: Color: [●] | position (bar.beat / time) */}
      <div className="flex items-center gap-3 min-h-[32px]">
        <div className="flex items-center gap-1.5">
          <span className="text-text-secondary text-xs flex-shrink-0">Color:</span>
          {colorSwatch}
        </div>

        <div className="w-px h-6 bg-border-default flex-shrink-0" />

        <div className="flex items-center gap-1.5">
          <span className="text-text-primary font-mono text-xs">{positionDisplay}</span>
          <span className="text-text-muted font-mono text-xs">/ {formatTime(currentMarker.position)}</span>
        </div>
      </div>
    </div>
  );
}
