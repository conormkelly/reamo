/**
 * Action Button Component
 * Triggers any REAPER action by command ID
 */

import { useState, useRef, useCallback, type ReactElement, type ReactNode } from 'react';
import { Gauge, Undo2, Redo2, Save, MapPinPlus, Minus, Plus, SkipBack, SkipForward, X } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useReaperStore } from '../../store';
import * as commands from '../../core/CommandBuilder';

// Hold duration threshold in ms
const HOLD_THRESHOLD = 300;

export interface ActionButtonProps {
  /** REAPER action command ID (number or registered string ID like "_RS...") */
  actionId: number | string;
  /** Button label */
  children: ReactNode;
  className?: string;
  /** Optional title/tooltip */
  title?: string;
  /** Button variant */
  variant?: 'default' | 'primary' | 'danger' | 'ghost';
  /** Button size */
  size?: 'sm' | 'md' | 'lg';
  /** Disabled state */
  disabled?: boolean;
}

/**
 * Button that triggers any REAPER action
 *
 * Common action IDs:
 * - 1007: Play
 * - 1008: Pause
 * - 1013: Record
 * - 40667: Stop
 * - 40364: Toggle Metronome
 * - 1068: Toggle Repeat
 * - 40172: Previous Marker
 * - 40173: Next Marker
 * - 40029: Undo
 * - 40030: Redo
 * - 40026: Save Project
 *
 * Find more IDs in REAPER's Action List (right-click → Copy command ID)
 */
export function ActionButton({
  actionId,
  children,
  className = '',
  title,
  variant = 'default',
  size = 'md',
  disabled = false,
}: ActionButtonProps): ReactElement {
  const { send } = useReaper();

  const handleClick = () => {
    if (!disabled) {
      send(commands.action(actionId));
    }
  };

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  const variantClasses = {
    default: 'bg-gray-700 text-white hover:bg-gray-600 active:bg-gray-500',
    primary: 'bg-blue-600 text-white hover:bg-blue-500 active:bg-blue-700',
    danger: 'bg-red-600 text-white hover:bg-red-500 active:bg-red-700',
    ghost: 'bg-transparent text-gray-300 hover:bg-gray-800 active:bg-gray-700',
  };

  return (
    <button
      onClick={handleClick}
      disabled={disabled}
      title={title}
      className={`
        ${sizeClasses[size]}
        ${variantClasses[variant]}
        rounded font-medium transition-colors
        disabled:opacity-50 disabled:cursor-not-allowed
        ${className}
      `}
    >
      {children}
    </button>
  );
}

// Pre-configured common action buttons

export interface MetronomeButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

// SWS action IDs for metronome volume
const SWS_METRO_VOL_DOWN = '_S&M_METRO_VOL_DOWN';
const SWS_METRO_VOL_UP = '_S&M_METRO_VOL_UP';

// SWS action IDs for count-in
const SWS_COUNT_IN_RECORD = '_SWS_AWCOUNTRECTOG';
const SWS_COUNT_IN_PLAYBACK = '_SWS_AWCOUNTPLAYTOG';

/**
 * Metronome button with long-press for volume control
 * - Tap: Toggle metronome on/off
 * - Long press: Open volume adjustment dialog with +/- buttons
 */
export function MetronomeButton({
  className = '',
  size = 'md',
}: MetronomeButtonProps): ReactElement {
  const { send } = useReaper();
  const isMetronome = useReaperStore((state) => state.isMetronome);
  const isCountInRecord = useReaperStore((state) => state.isCountInRecord);
  const isCountInPlayback = useReaperStore((state) => state.isCountInPlayback);

  // Long-press state
  const [showDialog, setShowDialog] = useState(false);
  const holdTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const wasHoldRef = useRef(false);

  const handlePointerDown = useCallback(() => {
    wasHoldRef.current = false;
    holdTimerRef.current = setTimeout(() => {
      wasHoldRef.current = true;
      setShowDialog(true);
    }, HOLD_THRESHOLD);
  }, []);

  const handlePointerUp = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
    // If it wasn't a hold, toggle metronome
    if (!wasHoldRef.current && !showDialog) {
      send(commands.toggleMetronome());
    }
  }, [send, showDialog]);

  const handlePointerCancel = useCallback(() => {
    if (holdTimerRef.current) {
      clearTimeout(holdTimerRef.current);
      holdTimerRef.current = null;
    }
  }, []);

  const handleVolumeUp = useCallback(() => {
    send(commands.action(SWS_METRO_VOL_UP));
  }, [send]);

  const handleVolumeDown = useCallback(() => {
    send(commands.action(SWS_METRO_VOL_DOWN));
  }, [send]);

  const handleToggleCountInRecord = useCallback(() => {
    send(commands.action(SWS_COUNT_IN_RECORD));
  }, [send]);

  const handleToggleCountInPlayback = useCallback(() => {
    send(commands.action(SWS_COUNT_IN_PLAYBACK));
  }, [send]);

  const handleOverlayClick = useCallback(
    (e: React.MouseEvent) => {
      if (e.target === e.currentTarget) {
        setShowDialog(false);
      }
    },
    []
  );

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  const activeClass = isMetronome
    ? 'bg-yellow-500/20 text-yellow-500 hover:bg-yellow-500/30'
    : 'bg-gray-700 text-gray-300 hover:bg-gray-600';

  return (
    <>
      <button
        onPointerDown={handlePointerDown}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerCancel}
        onPointerLeave={handlePointerCancel}
        title="Toggle Metronome - hold for volume"
        className={`
          ${sizeClasses[size]}
          ${activeClass}
          rounded font-medium transition-colors touch-none select-none
          ${className}
        `}
      >
        <Gauge size={16} className="inline-block align-middle mr-1" />
        <span className="align-middle">Click</span>
      </button>

      {/* Volume Dialog */}
      {showDialog && (
        <div
          className="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
          onClick={handleOverlayClick}
        >
          <div className="bg-gray-800 rounded-lg p-4 shadow-xl border border-gray-700 min-w-[200px]">
            {/* Volume Section */}
            <div className="text-sm text-gray-400 mb-3 text-center">Metronome Volume</div>
            <div className="flex items-center justify-center gap-4">
              <button
                onClick={handleVolumeDown}
                className="w-14 h-14 rounded-lg bg-gray-700 hover:bg-gray-600 active:bg-gray-500 flex items-center justify-center text-2xl"
              >
                <Minus size={28} />
              </button>
              <button
                onClick={handleVolumeUp}
                className="w-14 h-14 rounded-lg bg-gray-700 hover:bg-gray-600 active:bg-gray-500 flex items-center justify-center text-2xl"
              >
                <Plus size={28} />
              </button>
            </div>
            <div className="text-xs text-gray-500 mt-2 text-center">
              ~0.2 dB per tap
            </div>

            {/* Divider */}
            <div className="border-t border-gray-700 my-4" />

            {/* Count-In Section */}
            <div className="text-sm text-gray-400 mb-3 text-center">Count-In</div>
            <div className="flex items-center justify-center gap-3">
              <button
                onClick={handleToggleCountInRecord}
                className={`px-4 py-2 rounded-lg font-medium transition-colors ${
                  isCountInRecord
                    ? 'bg-red-500/20 text-red-400 hover:bg-red-500/30'
                    : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
                }`}
              >
                Record
              </button>
              <button
                onClick={handleToggleCountInPlayback}
                className={`px-4 py-2 rounded-lg font-medium transition-colors ${
                  isCountInPlayback
                    ? 'bg-green-500/20 text-green-400 hover:bg-green-500/30'
                    : 'bg-gray-700 text-gray-300 hover:bg-gray-600'
                }`}
              >
                Playback
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

export interface UndoButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

export function UndoButton({
  className = '',
  size = 'md',
}: UndoButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40029}
      title="Undo"
      className={className}
      size={size}
    >
      <Undo2 size={16} className="inline-block align-middle mr-1" />
      <span className="align-middle">Undo</span>
    </ActionButton>
  );
}

export interface RedoButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

export function RedoButton({
  className = '',
  size = 'md',
}: RedoButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40030}
      title="Redo"
      className={className}
      size={size}
    >
      <Redo2 size={16} className="inline-block align-middle mr-1" />
      <span className="align-middle">Redo</span>
    </ActionButton>
  );
}

export interface SaveButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

export function SaveButton({
  className = '',
  size = 'md',
}: SaveButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40026}
      title="Save Project"
      variant="primary"
      className={className}
      size={size}
    >
      <Save size={16} className="inline-block align-middle mr-1" />
      <span className="align-middle">Save</span>
    </ActionButton>
  );
}

export interface AddMarkerButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Button to insert a marker at the current playback position
 * Action ID 40157: Insert marker at current position
 */
export function AddMarkerButton({
  className = '',
  size = 'md',
}: AddMarkerButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40157}
      title="Add Marker"
      className={`flex items-center ${className}`}
      size={size}
    >
      <MapPinPlus size={16} className="mr-1" />
      <span>Add Marker</span>
    </ActionButton>
  );
}

export interface PrevMarkerButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Button to go to previous marker or project start
 * Action ID 40172: Go to previous marker/project start
 */
export function PrevMarkerButton({
  className = '',
  size = 'md',
}: PrevMarkerButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40172}
      title="Previous Marker"
      className={`flex items-center ${className}`}
      size={size}
    >
      <SkipBack size={20} />
    </ActionButton>
  );
}

export interface NextMarkerButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Button to go to next marker or project end
 * Action ID 40173: Go to next marker/project end
 */
export function NextMarkerButton({
  className = '',
  size = 'md',
}: NextMarkerButtonProps): ReactElement {
  return (
    <ActionButton
      actionId={40173}
      title="Next Marker"
      className={`flex items-center ${className}`}
      size={size}
    >
      <SkipForward size={20} />
    </ActionButton>
  );
}

export interface ClearSelectionButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Button to clear time selection and loop points
 * Action ID 40020: Remove (unselect) time selection and loop points
 * Also clears the local UI state for the selection
 */
export function ClearSelectionButton({
  className = '',
  size = 'md',
}: ClearSelectionButtonProps): ReactElement {
  const { send } = useReaper();
  const setTimeSelection = useReaperStore((state) => state.setTimeSelection);

  const handleClick = useCallback(() => {
    send(commands.action(40020));
    setTimeSelection(null);
  }, [send, setTimeSelection]);

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm',
    md: 'px-3 py-2',
    lg: 'px-4 py-3 text-lg',
  };

  return (
    <button
      onClick={handleClick}
      title="Clear Selection"
      className={`
        ${sizeClasses[size]}
        bg-gray-700 text-white hover:bg-gray-600 active:bg-gray-500
        rounded font-medium transition-colors flex items-center
        ${className}
      `}
    >
      <X size={16} className="mr-1" />
      <span>Clear</span>
    </button>
  );
}
