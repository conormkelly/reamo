/**
 * ColorPickerInput - Compact color picker with system picker + hex input
 */

import { useCallback } from 'react';
import { RotateCcw } from 'lucide-react';

interface ColorPickerInputProps {
  label: string;
  value: string;
  onChange: (color: string) => void;
  defaultValue: string;
}

export function ColorPickerInput({
  label,
  value,
  onChange,
  defaultValue,
}: ColorPickerInputProps) {
  const handleHexChange = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      let val = e.target.value;
      // Allow empty or partial hex values during typing
      if (val === '') {
        onChange(defaultValue);
        return;
      }
      // Add # if missing
      if (!val.startsWith('#')) {
        val = '#' + val;
      }
      // Validate hex format (allow partial for typing)
      if (/^#[0-9a-fA-F]{0,6}$/.test(val)) {
        onChange(val);
      }
    },
    [onChange, defaultValue]
  );

  const handleReset = useCallback(() => {
    onChange(defaultValue);
  }, [onChange, defaultValue]);

  const isDefault = value === defaultValue;

  return (
    <div>
      <label className="block text-xs text-gray-400 mb-1">{label}</label>
      <div className="flex gap-1">
        <input
          type="color"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          className="w-8 h-8 rounded border border-gray-600 cursor-pointer bg-gray-900"
        />
        <input
          type="text"
          value={value}
          onChange={handleHexChange}
          className="flex-1 px-2 py-1 bg-gray-900 border border-gray-600 rounded text-white text-xs font-mono w-20"
          placeholder={defaultValue}
        />
        {!isDefault && (
          <button
            onClick={handleReset}
            className="p-1 bg-gray-700 hover:bg-gray-600 rounded transition-colors"
            title="Reset to default"
          >
            <RotateCcw size={14} className="text-gray-400" />
          </button>
        )}
      </div>
    </div>
  );
}
