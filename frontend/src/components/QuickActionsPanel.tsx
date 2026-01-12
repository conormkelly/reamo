/**
 * QuickActionsPanel - Project-level quick actions
 *
 * Slide-up panel triggered by double-tap on time display.
 * Provides fast access to: Save, Undo/Redo, Metronome, Repeat, Tempo controls.
 */

import { useCallback, useState, useRef, useEffect, type ReactElement } from 'react';
import { Save, Undo2, Redo2, Gauge, Repeat, Minus, Plus } from 'lucide-react';
import { BottomSheet } from './Modal/BottomSheet';
import { useReaper } from './ReaperProvider';
import { useReaperStore } from '../store';
import { action, metronome, repeat, tempo } from '../core/WebSocketCommands';

export interface QuickActionsPanelProps {
  isOpen: boolean;
  onClose: () => void;
}

export function QuickActionsPanel({ isOpen, onClose }: QuickActionsPanelProps): ReactElement {
  const { sendCommand } = useReaper();

  // Project state
  const projectName = useReaperStore((s) => s.projectName);
  const isProjectDirty = useReaperStore((s) => s.isProjectDirty);
  const reaperCanUndo = useReaperStore((s) => s.reaperCanUndo);
  const reaperCanRedo = useReaperStore((s) => s.reaperCanRedo);

  // Transport state
  const isMetronome = useReaperStore((s) => s.isMetronome);
  const isRepeat = useReaperStore((s) => s.isRepeat);
  const bpm = useReaperStore((s) => s.bpm);
  const setBpm = useReaperStore((s) => s.setBpm);

  // Tempo input state
  const [showTempoInput, setShowTempoInput] = useState(false);
  const [tempoInputValue, setTempoInputValue] = useState('');
  const tempoInputRef = useRef<HTMLInputElement>(null);

  // Handle actions
  const handleSave = useCallback(() => {
    if (isProjectDirty) {
      sendCommand(action.execute(40026)); // Save Project
      onClose();
    }
  }, [sendCommand, isProjectDirty, onClose]);

  const handleUndo = useCallback(() => {
    if (reaperCanUndo) {
      sendCommand({ command: 'undo/do' });
    }
  }, [sendCommand, reaperCanUndo]);

  const handleRedo = useCallback(() => {
    if (reaperCanRedo) {
      sendCommand({ command: 'redo/do' });
    }
  }, [sendCommand, reaperCanRedo]);

  const handleMetronome = useCallback(() => {
    sendCommand(metronome.toggle());
  }, [sendCommand]);

  const handleRepeat = useCallback(() => {
    sendCommand(repeat.toggle());
  }, [sendCommand]);

  const handleTapTempo = useCallback(() => {
    sendCommand(tempo.tap());
  }, [sendCommand]);

  // Tempo editing
  const handleBpmClick = useCallback(() => {
    setTempoInputValue(bpm !== null ? String(Math.round(bpm)) : '120');
    setShowTempoInput(true);
  }, [bpm]);

  useEffect(() => {
    if (showTempoInput && tempoInputRef.current) {
      tempoInputRef.current.focus();
      tempoInputRef.current.select();
    }
  }, [showTempoInput]);

  const applyTempo = useCallback(
    (newBpm: number) => {
      const clampedBpm = Math.max(2, Math.min(960, Math.round(newBpm)));
      setBpm(clampedBpm);
      sendCommand(tempo.set(clampedBpm));
    },
    [sendCommand, setBpm]
  );

  const handleTempoInputKeyDown = useCallback(
    (e: React.KeyboardEvent<HTMLInputElement>) => {
      if (e.key === 'Enter') {
        const newBpm = parseInt(tempoInputValue, 10);
        if (!isNaN(newBpm)) {
          applyTempo(newBpm);
        }
        setShowTempoInput(false);
      } else if (e.key === 'Escape') {
        setShowTempoInput(false);
      }
    },
    [tempoInputValue, applyTempo]
  );

  const handleTempoInputBlur = useCallback(() => {
    const newBpm = parseInt(tempoInputValue, 10);
    if (!isNaN(newBpm)) {
      applyTempo(newBpm);
    }
    setShowTempoInput(false);
  }, [tempoInputValue, applyTempo]);

  const handleTempoIncrement = useCallback(() => {
    const currentBpm = bpm !== null ? Math.round(bpm) : 120;
    applyTempo(currentBpm + 1);
  }, [bpm, applyTempo]);

  const handleTempoDecrement = useCallback(() => {
    const currentBpm = bpm !== null ? Math.round(bpm) : 120;
    applyTempo(currentBpm - 1);
  }, [bpm, applyTempo]);

  // Format display name
  const displayName = projectName || 'Untitled';

  return (
    <BottomSheet isOpen={isOpen} onClose={onClose} ariaLabel="Quick actions panel">
      <div className="px-4 pb-6">
        {/* Project Name Header */}
        <div className="text-center mb-4 pt-1">
          <h2 className="text-lg font-semibold text-text-primary truncate">
            {displayName}
            {isProjectDirty && <span className="text-warning ml-1">*</span>}
          </h2>
        </div>

        {/* Project Actions Row */}
        <div className="flex justify-center gap-3 mb-4">
          <button
            onClick={handleSave}
            disabled={!isProjectDirty}
            title={isProjectDirty ? 'Save Project' : 'No unsaved changes'}
            className={`flex flex-col items-center justify-center w-20 h-16 rounded-xl transition-colors ${
              isProjectDirty
                ? 'bg-success-action text-text-on-success hover:bg-success active:bg-success-action'
                : 'bg-bg-elevated text-text-muted cursor-not-allowed opacity-50'
            }`}
          >
            <Save size={24} />
            <span className="text-xs mt-1">Save</span>
          </button>

          <button
            onClick={handleUndo}
            disabled={!reaperCanUndo}
            title={reaperCanUndo ? `Undo: ${reaperCanUndo}` : 'Nothing to undo'}
            className={`flex flex-col items-center justify-center w-20 h-16 rounded-xl transition-colors ${
              reaperCanUndo
                ? 'bg-bg-elevated text-text-primary hover:bg-bg-hover active:bg-bg-disabled'
                : 'bg-bg-elevated text-text-muted cursor-not-allowed opacity-50'
            }`}
          >
            <Undo2 size={24} />
            <span className="text-xs mt-1">Undo</span>
          </button>

          <button
            onClick={handleRedo}
            disabled={!reaperCanRedo}
            title={reaperCanRedo ? `Redo: ${reaperCanRedo}` : 'Nothing to redo'}
            className={`flex flex-col items-center justify-center w-20 h-16 rounded-xl transition-colors ${
              reaperCanRedo
                ? 'bg-bg-elevated text-text-primary hover:bg-bg-hover active:bg-bg-disabled'
                : 'bg-bg-elevated text-text-muted cursor-not-allowed opacity-50'
            }`}
          >
            <Redo2 size={24} />
            <span className="text-xs mt-1">Redo</span>
          </button>
        </div>

        {/* Divider */}
        <div className="border-t border-border-subtle my-4" />

        {/* Transport Toggles Row */}
        <div className="flex justify-center gap-3 mb-4">
          <button
            onClick={handleMetronome}
            title="Toggle Metronome"
            aria-pressed={isMetronome}
            className={`flex items-center justify-center gap-2 px-6 h-12 rounded-xl font-medium transition-colors ${
              isMetronome
                ? 'bg-metronome-bg text-metronome hover:bg-metronome-hover'
                : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
            }`}
          >
            <Gauge size={20} />
            <span>Click</span>
          </button>

          <button
            onClick={handleRepeat}
            title="Toggle Repeat/Loop"
            aria-pressed={isRepeat}
            className={`flex items-center justify-center gap-2 px-6 h-12 rounded-xl font-medium transition-colors ${
              isRepeat
                ? 'bg-success-action text-text-on-success hover:bg-success'
                : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
            }`}
          >
            <Repeat size={20} />
            <span>Loop</span>
          </button>
        </div>

        {/* Divider */}
        <div className="border-t border-border-subtle my-4" />

        {/* Tempo Row */}
        <div className="flex justify-center items-center gap-3">
          <button
            onClick={handleTempoDecrement}
            title="Decrease Tempo"
            className="w-12 h-12 rounded-xl bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled flex items-center justify-center transition-colors"
          >
            <Minus size={24} />
          </button>

          {showTempoInput ? (
            <input
              ref={tempoInputRef}
              type="text"
              inputMode="numeric"
              pattern="[0-9]*"
              value={tempoInputValue}
              onChange={(e) => setTempoInputValue(e.target.value.replace(/[^0-9]/g, ''))}
              onKeyDown={handleTempoInputKeyDown}
              onBlur={handleTempoInputBlur}
              className="w-24 h-12 text-center text-xl font-mono bg-bg-deep border border-border-default rounded-xl focus:border-primary focus:outline-none"
            />
          ) : (
            <button
              onClick={handleBpmClick}
              title="Tap to edit tempo"
              className="w-24 h-12 rounded-xl bg-bg-elevated hover:bg-bg-hover text-xl font-mono font-medium transition-colors"
            >
              {bpm !== null ? Math.round(bpm) : '-'}
            </button>
          )}

          <button
            onClick={handleTempoIncrement}
            title="Increase Tempo"
            className="w-12 h-12 rounded-xl bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled flex items-center justify-center transition-colors"
          >
            <Plus size={24} />
          </button>

          <button
            onClick={handleTapTempo}
            title="Tap Tempo"
            className="h-12 px-4 rounded-xl bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled font-medium transition-colors"
          >
            Tap
          </button>
        </div>

        <div className="text-xs text-text-muted text-center mt-2">BPM</div>
      </div>
    </BottomSheet>
  );
}
