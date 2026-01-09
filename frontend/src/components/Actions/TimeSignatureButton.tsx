/**
 * Time Signature Button Component
 * Displays current time signature and allows changing it via modal
 */

import { useState, useCallback, type ReactElement } from 'react';
import { Minus, Plus } from 'lucide-react';
import { useReaper } from '../ReaperProvider';
import { useTimeSignature } from '../../hooks';
import { timesig } from '../../core/WebSocketCommands';

// Common time signature presets
const TIME_SIG_PRESETS = [
  { num: 3, denom: 4, label: '3/4' },
  { num: 4, denom: 4, label: '4/4' },
  { num: 6, denom: 8, label: '6/8' },
];

// Valid denominators (note values)
const VALID_DENOMINATORS = [2, 4, 8, 16];

export interface TimeSignatureButtonProps {
  className?: string;
  size?: 'sm' | 'md' | 'lg';
}

/**
 * Button that displays time signature and opens modal to change it
 * - Tap: opens time signature editor
 */
export function TimeSignatureButton({
  className = '',
  size = 'md',
}: TimeSignatureButtonProps): ReactElement {
  const { sendCommand } = useReaper();
  const { beatsPerBar: storeBeatsPerBar, denominator: storeDenominator } = useTimeSignature();

  const [showDialog, setShowDialog] = useState(false);
  const [numerator, setNumerator] = useState(4);
  const [denominator, setDenominator] = useState(4);

  // Use store values when opening dialog
  const handleClick = useCallback(() => {
    setNumerator(storeBeatsPerBar);
    setDenominator(storeDenominator);
    setShowDialog(true);
  }, [storeBeatsPerBar, storeDenominator]);

  const handleSetTimeSignature = useCallback(
    (num: number, denom: number) => {
      sendCommand(timesig.set(num, denom));
      setShowDialog(false);
    },
    [sendCommand]
  );

  const handleNumeratorUp = useCallback(() => {
    setNumerator((n) => Math.min(32, n + 1));
  }, []);

  const handleNumeratorDown = useCallback(() => {
    setNumerator((n) => Math.max(1, n - 1));
  }, []);

  const handleDenominatorUp = useCallback(() => {
    setDenominator((d) => {
      const idx = VALID_DENOMINATORS.indexOf(d);
      return idx < VALID_DENOMINATORS.length - 1 ? VALID_DENOMINATORS[idx + 1] : d;
    });
  }, []);

  const handleDenominatorDown = useCallback(() => {
    setDenominator((d) => {
      const idx = VALID_DENOMINATORS.indexOf(d);
      return idx > 0 ? VALID_DENOMINATORS[idx - 1] : d;
    });
  }, []);

  const handlePreset = useCallback(
    (num: number, denom: number) => {
      setNumerator(num);
      setDenominator(denom);
      handleSetTimeSignature(num, denom);
    },
    [handleSetTimeSignature]
  );

  const handleApply = useCallback(() => {
    handleSetTimeSignature(numerator, denominator);
  }, [numerator, denominator, handleSetTimeSignature]);

  const handleOverlayClick = useCallback((e: React.MouseEvent) => {
    if (e.target === e.currentTarget) {
      setShowDialog(false);
    }
  }, []);

  const sizeClasses = {
    sm: 'px-2 py-1 text-sm min-w-12',
    md: 'px-3 py-2 min-w-14',
    lg: 'px-4 py-3 text-lg min-w-16',
  };

  return (
    <>
      <button
        onClick={handleClick}
        title="Time Signature - tap to change"
        className={`
          ${sizeClasses[size]}
          bg-bg-elevated text-text-primary hover:bg-bg-hover active:bg-bg-disabled
          rounded font-medium font-mono transition-colors
          ${className}
        `}
      >
        {storeBeatsPerBar}/{storeDenominator}
      </button>

      {/* Time Signature Dialog */}
      {showDialog && (
        <div
          className="fixed inset-0 bg-black/50 flex items-center justify-center z-50"
          onClick={handleOverlayClick}
        >
          <div className="bg-bg-surface rounded-lg p-4 shadow-xl border border-border-subtle min-w-[220px]">
            <div className="text-sm text-text-secondary mb-4 text-center">Time Signature</div>

            {/* Numerator */}
            <div className="flex items-center justify-center gap-3 mb-2">
              <button
                onClick={handleNumeratorDown}
                className="w-10 h-10 rounded bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled flex items-center justify-center"
              >
                <Minus size={20} />
              </button>
              <div className="w-12 h-12 flex items-center justify-center text-2xl font-mono font-bold">
                {numerator}
              </div>
              <button
                onClick={handleNumeratorUp}
                className="w-10 h-10 rounded bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled flex items-center justify-center"
              >
                <Plus size={20} />
              </button>
            </div>

            {/* Divider line */}
            <div className="w-20 h-0.5 bg-bg-disabled mx-auto mb-2" />

            {/* Denominator */}
            <div className="flex items-center justify-center gap-3 mb-4">
              <button
                onClick={handleDenominatorDown}
                className="w-10 h-10 rounded bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled flex items-center justify-center"
              >
                <Minus size={20} />
              </button>
              <div className="w-12 h-12 flex items-center justify-center text-2xl font-mono font-bold">
                {denominator}
              </div>
              <button
                onClick={handleDenominatorUp}
                className="w-10 h-10 rounded bg-bg-elevated hover:bg-bg-hover active:bg-bg-disabled flex items-center justify-center"
              >
                <Plus size={20} />
              </button>
            </div>

            {/* Apply button */}
            <button
              onClick={handleApply}
              className="w-full py-2 mb-4 rounded bg-primary hover:bg-primary-hover active:bg-primary-active font-medium transition-colors"
            >
              Apply {numerator}/{denominator}
            </button>

            {/* Presets */}
            <div className="text-xs text-text-muted mb-2 text-center">Presets</div>
            <div className="flex items-center justify-center gap-2">
              {TIME_SIG_PRESETS.map((preset) => (
                <button
                  key={preset.label}
                  onClick={() => handlePreset(preset.num, preset.denom)}
                  className={`px-3 py-1.5 rounded text-sm font-mono transition-colors ${
                    numerator === preset.num && denominator === preset.denom
                      ? 'bg-primary text-text-primary'
                      : 'bg-bg-elevated text-text-tertiary hover:bg-bg-hover'
                  }`}
                >
                  {preset.label}
                </button>
              ))}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
