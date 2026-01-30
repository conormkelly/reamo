/**
 * TunerSettings - Tuner configuration
 *
 * Reference frequency: A4 tuning reference (default 440Hz)
 * Silence threshold: dB level below which input is ignored (default -60dB)
 */

import { type ReactElement } from 'react';
import { Settings, Check } from 'lucide-react';
import { BottomSheet } from '../../components/Modal/BottomSheet';

export interface TunerSettingsProps {
  referenceHz: number;
  onReferenceChange: (hz: number) => void;
  thresholdDb: number;
  onThresholdChange: (db: number) => void;
  showSettings: boolean;
  onToggleSettings: () => void;
}

// Common reference frequencies
const REFERENCE_PRESETS = [
  { hz: 432, label: '432 Hz', description: 'Alternative tuning' },
  { hz: 440, label: '440 Hz', description: 'Standard concert pitch' },
  { hz: 442, label: '442 Hz', description: 'Orchestral (common)' },
  { hz: 443, label: '443 Hz', description: 'European orchestras' },
];

export function TunerSettings({
  referenceHz,
  onReferenceChange,
  thresholdDb,
  onThresholdChange,
  showSettings,
  onToggleSettings,
}: TunerSettingsProps): ReactElement {
  return (
    <>
      {/* Settings trigger */}
      <button
        onClick={onToggleSettings}
        className="flex items-center justify-center gap-2 w-full py-2 rounded-lg bg-bg-elevated hover:bg-bg-hover transition-colors text-sm"
      >
        <Settings size={16} className="text-text-tertiary" />
        <span className="text-text-secondary">Reference: {referenceHz} Hz</span>
      </button>

      {/* Settings bottom sheet */}
      <BottomSheet
        isOpen={showSettings}
        onClose={onToggleSettings}
        ariaLabel="Tuner Settings"
      >
        <h2 className="text-lg font-semibold text-text-primary px-4 pb-3">Tuner Settings</h2>
        <div className="flex flex-col gap-4 pb-4">
          {/* Reference frequency section */}
          <div>
            <h3 className="text-sm font-medium text-text-secondary mb-3 px-4">
              Reference Frequency
            </h3>
            <div className="flex flex-col">
              {REFERENCE_PRESETS.map((preset) => (
                <button
                  key={preset.hz}
                  onClick={() => onReferenceChange(preset.hz)}
                  className={`flex items-center justify-between px-4 py-3 hover:bg-bg-hover transition-colors ${
                    referenceHz === preset.hz ? 'bg-bg-elevated' : ''
                  }`}
                >
                  <div className="flex flex-col items-start">
                    <span className="font-medium">{preset.label}</span>
                    <span className="text-xs text-text-tertiary">{preset.description}</span>
                  </div>
                  {referenceHz === preset.hz && (
                    <Check size={18} className="text-primary" />
                  )}
                </button>
              ))}
            </div>
          </div>

          {/* Custom frequency input */}
          <div className="px-4">
            <label className="text-sm font-medium text-text-secondary block mb-2">
              Custom (400–480 Hz)
            </label>
            <input
              type="number"
              inputMode="numeric"
              min={400}
              max={480}
              step={1}
              value={referenceHz}
              onChange={(e) => {
                const value = parseFloat(e.target.value);
                if (!isNaN(value) && value >= 400 && value <= 480) {
                  onReferenceChange(value);
                }
              }}
              onTouchStart={(e) => (e.target as HTMLInputElement).focus()}
              className="w-full px-3 py-2 rounded-lg bg-bg-elevated border border-border-muted text-text-primary focus:outline-none focus:ring-2 focus:ring-primary"
            />
          </div>

          {/* Silence threshold section */}
          <div className="px-4 pt-2 border-t border-border-muted">
            <div className="flex items-center justify-between mb-2">
              <label className="text-sm font-medium text-text-secondary">
                Input Threshold
              </label>
              <span className="text-sm text-text-tertiary">{thresholdDb} dB</span>
            </div>
            <input
              type="range"
              min={-90}
              max={-30}
              step={1}
              value={thresholdDb}
              onChange={(e) => onThresholdChange(parseInt(e.target.value, 10))}
              className="w-full accent-primary"
            />
            <p className="text-xs text-text-muted mt-1">
              Signals below this level are ignored
            </p>
          </div>
        </div>
      </BottomSheet>
    </>
  );
}
